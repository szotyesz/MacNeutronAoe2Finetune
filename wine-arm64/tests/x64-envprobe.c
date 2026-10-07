// What an x64 program sees of the machine and of a debugger under FEX (aoe2 N3, finding N3-F1: AoE2DE's Arxan
// anti-tamper leaves code unrepaired on this runtime). It prints CPUID, XGETBV, the usual debugger checks and how
// trap-type instructions are reported, one "key value" line each, for comparison with Windows on x64. It never fails:
// it is a probe, and the comparison is done by reading its output.
#include <windows.h>
#include <winternl.h>
#include <stdio.h>
#include <string.h>

typedef NTSTATUS (WINAPI *qip_fn)(HANDLE, ULONG, void *, ULONG, ULONG *);
typedef NTSTATUS (WINAPI *qsi_fn)(ULONG, void *, ULONG, ULONG *);
typedef NTSTATUS (WINAPI *sit_fn)(HANDLE, ULONG, void *, ULONG);

static void cpuid(unsigned leaf, unsigned sub, int r[4]) {
  __asm__ volatile("cpuid" : "=a"(r[0]), "=b"(r[1]), "=c"(r[2]), "=d"(r[3]) : "a"(leaf), "c"(sub));
}
static unsigned long long xgetbv0(void) {
  unsigned lo, hi;
  __asm__ volatile("xgetbv" : "=a"(lo), "=d"(hi) : "c"(0));
  return ((unsigned long long)hi << 32) | lo;
}

static unsigned long long rdtsc(void) {
  unsigned lo, hi;
  __asm__ volatile("rdtsc" : "=a"(lo), "=d"(hi));
  return ((unsigned long long)hi << 32) | lo;
}

static void dump_cpuid(void) {
  int r[4];
  char s[49];
  unsigned max, maxx, i;
  cpuid(0, 0, r);
  max = (unsigned)r[0];
  memcpy(s, &r[1], 4); memcpy(s + 4, &r[3], 4); memcpy(s + 8, &r[2], 4); s[12] = 0;
  printf("cpuid.vendor %s max=0x%x\n", s, max);
  for (i = 1; i <= max && i <= 0x1f; i++) {
    cpuid(i, 0, r);
    printf("cpuid.%02x.0 eax=%08x ebx=%08x ecx=%08x edx=%08x\n", i, r[0], r[1], r[2], r[3]);
  }
  cpuid(7, 1, r);
  printf("cpuid.07.1 eax=%08x ebx=%08x ecx=%08x edx=%08x\n", r[0], r[1], r[2], r[3]);
  cpuid(1, 0, r);
  printf("cpuid.hypervisor_bit %d\n", (r[2] >> 31) & 1);
  printf("cpuid.osxsave %d avx %d sse4.2 %d popcnt %d aes %d\n", (r[2] >> 27) & 1, (r[2] >> 28) & 1, (r[2] >> 20) & 1,
         (r[2] >> 23) & 1, (r[2] >> 25) & 1);
  if ((r[2] >> 27) & 1) printf("xgetbv.0 0x%llx\n", xgetbv0());
  cpuid(0x40000000, 0, r);
  memcpy(s, &r[1], 4); memcpy(s + 4, &r[2], 4); memcpy(s + 8, &r[3], 4); s[12] = 0;
  printf("cpuid.40000000 eax=%08x vendor=\"%s\"\n", r[0], s);
  cpuid(0x80000000, 0, r);
  maxx = (unsigned)r[0];
  printf("cpuid.ext_max 0x%x\n", maxx);
  for (i = 0x80000001; i <= maxx && i <= 0x80000008; i++) {
    cpuid(i, 0, r);
    printf("cpuid.%08x eax=%08x ebx=%08x ecx=%08x edx=%08x\n", i, r[0], r[1], r[2], r[3]);
  }
  if (maxx >= 0x80000004) {
    for (i = 0; i < 3; i++) { cpuid(0x80000002 + i, 0, r); memcpy(s + 16 * i, r, 16); }
    s[48] = 0;
    printf("cpuid.brand \"%s\"\n", s);
  }
}

// One trap-type instruction at a time, under a vectored handler that records what Windows would show the program.
static volatile LONG seen_code;
static volatile ULONG_PTR seen_addr, seen_rip;
static volatile int seen_count;
static ULONG_PTR skip_to;
static LONG CALLBACK veh(EXCEPTION_POINTERS *ep) {
  if (!skip_to) return EXCEPTION_CONTINUE_SEARCH;
  seen_code = (LONG)ep->ExceptionRecord->ExceptionCode;
  seen_addr = (ULONG_PTR)ep->ExceptionRecord->ExceptionAddress;
  seen_rip = ep->ContextRecord->Rip;
  seen_count++;
  ep->ContextRecord->Rip = skip_to;
  ep->ContextRecord->EFlags &= ~0x100u;
  return EXCEPTION_CONTINUE_EXECUTION;
}

// Each stub: the instruction under test at label <name>_at, then <name>_after, where the handler resumes.
#define STUB(name, insns) \
  extern char name##_at[], name##_after[]; \
  __asm__(".text\n.globl " #name "\n" #name ":\n" insns "\n" #name "_after:\n\tret\n");
STUB(t_int3,   "t_int3_at:\n\tint3\n\tnop")
STUB(t_int2d,  "t_int2d_at:\n\tint $0x2d\n\tnop\n\tnop")
STUB(t_icebp,  "t_icebp_at:\n\t.byte 0xf1\n\tnop")
STUB(t_ud2,    "t_ud2_at:\n\tud2\n\tnop")
STUB(t_op60,   "t_op60_at:\n\t.byte 0x60\n\tnop")
STUB(t_tf,     "\tpushfq\n\torq $0x100, (%rsp)\n\tpopfq\nt_tf_at:\n\tnop\n\tnop\n\tnop")
STUB(t_priv,   "t_priv_at:\n\thlt\n\tnop")
STUB(t_rdtscp, "t_rdtscp_at:\n\trdtscp\n\tnop")
extern void t_int3(void), t_int2d(void), t_icebp(void), t_ud2(void), t_op60(void), t_tf(void), t_priv(void),
  t_rdtscp(void);

static void trap(const char *name, void (*fn)(void), char *at, char *after) {
  seen_code = 0; seen_addr = seen_rip = 0; seen_count = 0;
  skip_to = (ULONG_PTR)after;
  fn();
  skip_to = 0;
  printf("trap.%s code=%08lx count=%d addr=%s%+ld rip=at%+ld\n", name, (unsigned long)seen_code, seen_count,
         seen_addr ? "at" : "none", seen_addr ? (long)(seen_addr - (ULONG_PTR)at) : 0L,
         seen_rip ? (long)(seen_rip - (ULONG_PTR)at) : 0L);
}

int main(void) {
  HMODULE nt = GetModuleHandleA("ntdll.dll");
  qip_fn qip = (qip_fn)(void *)GetProcAddress(nt, "NtQueryInformationProcess");
  qsi_fn qsi = (qsi_fn)(void *)GetProcAddress(nt, "NtQuerySystemInformation");
  sit_fn sit = (sit_fn)(void *)GetProcAddress(nt, "NtSetInformationThread");
  PEB *peb = NtCurrentTeb()->ProcessEnvironmentBlock;
  ULONG_PTR port = 1, handle = 1;
  ULONG flags = 0, kd[2] = {0};
  BOOL remote = TRUE;
  NTSTATUS st;
  CONTEXT ctx = {.ContextFlags = CONTEXT_DEBUG_REGISTERS};
  LARGE_INTEGER f, q0, q1;
  unsigned long long t0, t1;
  setvbuf(stdout, NULL, _IONBF, 0);

  dump_cpuid();

  printf("dbg.IsDebuggerPresent %d\n", IsDebuggerPresent());
  printf("dbg.peb.BeingDebugged %d\n", peb->BeingDebugged);
  printf("dbg.peb.NtGlobalFlag 0x%lx\n", *(ULONG *)((char *)peb + 0xbc));
  CheckRemoteDebuggerPresent(GetCurrentProcess(), &remote);
  printf("dbg.CheckRemoteDebuggerPresent %d\n", remote);
  st = qip(GetCurrentProcess(), 7, &port, sizeof(port), NULL);
  printf("dbg.ProcessDebugPort status=%08lx value=%llu\n", (unsigned long)st, (unsigned long long)port);
  st = qip(GetCurrentProcess(), 0x1e, &handle, sizeof(handle), NULL);
  printf("dbg.ProcessDebugObjectHandle status=%08lx value=%llu\n", (unsigned long)st, (unsigned long long)handle);
  st = qip(GetCurrentProcess(), 0x1f, &flags, sizeof(flags), NULL);
  printf("dbg.ProcessDebugFlags status=%08lx value=%lu\n", (unsigned long)st, flags);
  st = qsi(0x23, kd, 2, NULL);  // SystemKernelDebuggerInformation: two BOOLEANs
  printf("dbg.SystemKernelDebugger status=%08lx enabled=%u not_present=%u\n", (unsigned long)st,
         ((unsigned char *)kd)[0], ((unsigned char *)kd)[1]);
  st = sit(GetCurrentThread(), 0x11, NULL, 0);  // ThreadHideFromDebugger
  printf("dbg.ThreadHideFromDebugger status=%08lx\n", (unsigned long)st);
  if (GetThreadContext(GetCurrentThread(), &ctx))
    printf("dbg.dr dr0=%llx dr1=%llx dr2=%llx dr3=%llx dr6=%llx dr7=%llx\n", ctx.Dr0, ctx.Dr1, ctx.Dr2, ctx.Dr3, ctx.Dr6,
           ctx.Dr7);
  else
    printf("dbg.dr GetThreadContext failed %lu\n", GetLastError());

  AddVectoredExceptionHandler(1, veh);
  {  // CloseHandle on a bad handle raises only under a debugger
    LONG before = seen_count;
    skip_to = 0;
    printf("dbg.CloseHandle_bad ret=%d err=%lu\n", CloseHandle((HANDLE)(ULONG_PTR)0x1234567), GetLastError());
    (void)before;
  }
  trap("int3", t_int3, t_int3_at, t_int3_after);
  trap("int2d", t_int2d, t_int2d_at, t_int2d_after);
  trap("icebp", t_icebp, t_icebp_at, t_icebp_after);
  trap("ud2", t_ud2, t_ud2_at, t_ud2_after);
  trap("op60", t_op60, t_op60_at, t_op60_after);
  trap("trapflag", t_tf, t_tf_at, t_tf_after);
  trap("hlt", t_priv, t_priv_at, t_priv_after);
  trap("rdtscp", t_rdtscp, t_rdtscp_at, t_rdtscp_after);

  QueryPerformanceFrequency(&f);
  QueryPerformanceCounter(&q0); t0 = rdtsc();
  Sleep(200);
  QueryPerformanceCounter(&q1); t1 = rdtsc();
  printf("time.rdtsc_hz %.0f qpc_hz %lld\n", (double)(t1 - t0) * (double)f.QuadPart / (double)(q1.QuadPart - q0.QuadPart),
         f.QuadPart);
  t0 = rdtsc(); t1 = rdtsc();
  printf("time.rdtsc_back_to_back %llu\n", t1 - t0);
  printf("DONE x64-envprobe\n");
  return 0;
}
