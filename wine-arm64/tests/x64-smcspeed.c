// Speed of code on a page FEX checks instead of write-protecting (aoe2 N3, finding F6; FEX downstream patch): a 5-
// instruction x64 loop runs on an execute-only page, and on an RWX page written to while it holds compiled code until
// FEX stops trapping writes to it (MACNEUTRON_SMC_SELFCHECK writes; FEX's default 16), so its blocks check their own
// bytes. Prints both times per loop iteration and their ratio; also checks that a rewrite of the self-checked code
// takes effect (the loop's multiplier changes from 3 to 5), and that one without FlushInstructionCache does too, as x86
// code may rely on: only the block's own check catches it, and its invalidation must not re-enter FEX's memory hooks
// when it frees FEX's own memory (that deadlocked the thread).
// Usage: x64-smcspeed.exe [iterations]   Prints "PASS x64-smcspeed" and "row <case> <ns per iteration>" lines.
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const BYTE loop_code[] = {
  0x31, 0xc0,             // xor eax, eax
  0x01, 0xc8,             // loop: add eax, ecx
  0x6b, 0xc0, 0x03,       // imul eax, eax, 3
  0x31, 0xc8,             // xor eax, ecx
  0xff, 0xc9,             // dec ecx
  0x75, 0xf5,             // jnz loop
  0xc3,                   // ret
};

typedef unsigned int (*loop_fn)(unsigned int);

static unsigned int reference(unsigned int n, unsigned int mul) {
  unsigned int a = 0;
  for (; n; n--) { a += n; a *= mul; a ^= n; }
  return a;
}

static double time_loop(loop_fn fn, unsigned int n) {
  LARGE_INTEGER f, t0, t1;
  QueryPerformanceFrequency(&f);
  QueryPerformanceCounter(&t0);
  volatile unsigned int r = fn(n);
  QueryPerformanceCounter(&t1);
  (void)r;
  return (double)(t1.QuadPart - t0.QuadPart) * 1e9 / f.QuadPart / n;
}

int main(int argc, char **argv) {
  unsigned int n = argc > 1 ? (unsigned int)strtoul(argv[1], NULL, 10) : 200000000u;
  int fails = 0;
  DWORD old;
  BYTE *ro = VirtualAlloc(NULL, 0x1000, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
  BYTE *rwx = VirtualAlloc(NULL, 0x1000, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
  setvbuf(stdout, NULL, _IONBF, 0);
  memcpy(ro, loop_code, sizeof(loop_code));
  VirtualProtect(ro, 0x1000, PAGE_EXECUTE_READ, &old);
  memcpy(rwx, loop_code, sizeof(loop_code));
  FlushInstructionCache(GetCurrentProcess(), ro, 0x1000);
  FlushInstructionCache(GetCurrentProcess(), rwx, 0x1000);

  // Compile, then write next to the code: each write hits a page that holds compiled code.
  for (int i = 0; i < 40; i++) {
    ((loop_fn)rwx)(1000);
    rwx[0x800 + i] = (BYTE)i;
  }

  double t_ro = time_loop((loop_fn)ro, n), t_rwx = time_loop((loop_fn)rwx, n);
  printf("row execute-only %.3f\n", t_ro);
  printf("row self-checked %.3f\n", t_rwx);
  printf("ratio %.2f\n", t_rwx / t_ro);

  // A rewrite of the multiplier must take effect.
  if (((loop_fn)rwx)(1000) != reference(1000, 3)) { printf("FAIL: wrong result before the rewrite\n"); fails++; }
  rwx[6] = 0x05;
  FlushInstructionCache(GetCurrentProcess(), rwx, 0x1000);
  if (((loop_fn)rwx)(1000) != reference(1000, 5)) { printf("FAIL: the rewrite did not take effect\n"); fails++; }
  rwx[6] = 0x03;
  if (((loop_fn)rwx)(1000) != reference(1000, 3)) { printf("FAIL: the rewrite without a flush did not take effect\n"); fails++; }

  if (fails) { printf("FAIL x64-smcspeed (%d)\n", fails); return 1; }
  printf("PASS x64-smcspeed\n");
  return 0;
}
