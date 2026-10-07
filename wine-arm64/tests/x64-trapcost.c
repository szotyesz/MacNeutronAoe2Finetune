// The cost of an illegal-instruction exception handled by a vectored handler that resumes after it, which is how
// AoE2DE's anti-tamper steers its code (aoe2 N3, finding N3-F3: ~720,000 of them in the first 80 s). Built for x64
// (under FEX: the trap is 0x06, invalid in 64-bit mode, one byte) and, from the same source, for ARM64 (native: udf,
// four bytes). Also times RaiseException to the same handler, which has no CPU trap, and a plain call for scale.
// Usage: <exe> [count]   Prints "trapcost <kind> <n> <microseconds per exception>"; ends with PASS when every
// exception reached the handler.
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

#ifdef __x86_64__
#define NAME "x64-trapcost"
#define TRAP_LEN 1
__asm__(".text\n.globl trap_once\ntrap_once:\n\t.byte 0x06\n\tret\n");
#define CTX_PC(c) ((c)->Rip)
#else
#define NAME "arm64-trapcost"
#define TRAP_LEN 4
__asm__(".text\n.globl trap_once\ntrap_once:\n\tudf #0\n\tret\n");
#define CTX_PC(c) ((c)->Pc)
#endif
extern void trap_once(void);

static volatile LONG handled;

static LONG CALLBACK veh(EXCEPTION_POINTERS *ep) {
  DWORD code = ep->ExceptionRecord->ExceptionCode;
  if (code == EXCEPTION_ILLEGAL_INSTRUCTION && CTX_PC(ep->ContextRecord) == (ULONG_PTR)trap_once) {
    CTX_PC(ep->ContextRecord) += TRAP_LEN;
    handled++;
    return EXCEPTION_CONTINUE_EXECUTION;
  }
  if (code == 0xe0aa0001) {
    handled++;
    return EXCEPTION_CONTINUE_EXECUTION;
  }
  return EXCEPTION_CONTINUE_SEARCH;
}

static __declspec(noinline) void plain(void) { __asm__ volatile(""); }

static double us_per(LARGE_INTEGER a, LARGE_INTEGER b, LARGE_INTEGER f, int n) {
  return (double)(b.QuadPart - a.QuadPart) * 1e6 / (double)f.QuadPart / n;
}

int main(int argc, char **argv) {
  int n = argc > 1 ? atoi(argv[1]) : 20000, i;
  LARGE_INTEGER f, a, b;
  int fails = 0;
  setvbuf(stdout, NULL, _IONBF, 0);
  QueryPerformanceFrequency(&f);
  AddVectoredExceptionHandler(1, veh);

  for (i = 0; i < 100; i++) trap_once();  // warm-up: the first trap compiles and maps things
  handled = 0;
  QueryPerformanceCounter(&a);
  for (i = 0; i < n; i++) trap_once();
  QueryPerformanceCounter(&b);
  printf("trapcost illegal-instruction %d %.2f\n", n, us_per(a, b, f, n));
  if (handled != n) { printf("illegal-instruction handled %ld of %d\n", handled, n); fails++; }

  handled = 0;
  QueryPerformanceCounter(&a);
  for (i = 0; i < n; i++) RaiseException(0xe0aa0001, 0, 0, NULL);
  QueryPerformanceCounter(&b);
  printf("trapcost raise-exception %d %.2f\n", n, us_per(a, b, f, n));
  if (handled != n) { printf("raise-exception handled %ld of %d\n", handled, n); fails++; }

  QueryPerformanceCounter(&a);
  for (i = 0; i < n * 100; i++) plain();
  QueryPerformanceCounter(&b);
  printf("trapcost plain-call %d %.4f\n", n * 100, us_per(a, b, f, n * 100));

  if (fails) { printf("FAIL " NAME "\n"); return 1; }
  printf("PASS " NAME "\n");
  return 0;
}
