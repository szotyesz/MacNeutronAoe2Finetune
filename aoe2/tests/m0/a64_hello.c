/* Ported from Aoe2MacSteamNoRosetta tests/hello-a64/a64_hello.c at f37dfc2 (plan R2, N2). */
/* A64-HELLO (plan §8 M0.4) — minimal Windows ARM64 console probe.
 *
 * Purpose: prove that the selected native Wine executes an unmodified
 * Windows ARM64 PE (machine 0xAA64, NOT ARM64EC) end to end:
 *   - the PE loader maps the image,
 *   - the CRT + KERNEL32 PID/TID APIs work,
 *   - stdout reaches the host terminal,
 *   - the loader propagates the guest exit code (23).
 *
 * Exact-oracle design: stdout carries a FIXED, deterministic line
 * ("A64-HELLO OK") so the "exact line" check is stable across runs; the
 * PID/TID API results (which vary) are asserted non-zero and reported on
 * stderr for evidence, not folded into the fixed line. Exit code is 23.
 *
 * Build (Windows ARM64 PE, no Wine required):
 *   <llvm-mingw>/bin/aarch64-w64-mingw32-gcc a64_hello.c -o a64_hello.exe
 * Machine type must be IMAGE_FILE_MACHINE_ARM64 (0xAA64); see
 * scripts/check-toolchains.sh (TC-A64) for the readobj verification.
 */
#include <windows.h>
#include <stdio.h>

int main(void)
{
    DWORD pid = GetCurrentProcessId();
    DWORD tid = GetCurrentThreadId();

    if (pid == 0 || tid == 0)
    {
        fprintf(stderr, "A64-HELLO-FAIL pid=%lu tid=%lu\n",
                (unsigned long)pid, (unsigned long)tid);
        return 99;
    }

    fprintf(stderr, "A64-HELLO-EVIDENCE pid=%lu tid=%lu\n",
            (unsigned long)pid, (unsigned long)tid);
    printf("A64-HELLO OK\n");
    fflush(stdout);
    return 23;
}
