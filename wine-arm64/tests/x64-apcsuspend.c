// A child sleeping alertably, while its parent allocates and frees memory in it (system APCs the child's thread runs)
// and suspends and resumes its thread, as Wine's kernel32 sync test_apc_deadlock does. Under FEX the child died in that
// test (aoe2 N2: "nested exception on signal stack" in _platform_memmove, then every remote call failed with
// STATUS_PROCESS_IS_TERMINATING); natively it lives. Usage: x64-apcsuspend [alloc|suspend|both|suspended-alloc]
// (default suspended-alloc: each remote allocation made while the child's thread is suspended, as the test does);
// the child is "x64-apcsuspend child". Passes when the child is still running after 1000 rounds.
#include <windows.h>
#include <winternl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef NTSTATUS (WINAPI *alloc_fn)(HANDLE, void **, ULONG_PTR, SIZE_T *, ULONG, ULONG);
typedef NTSTATUS (WINAPI *free_fn)(HANDLE, void **, SIZE_T *, ULONG);
static alloc_fn pNtAllocateVirtualMemory;
static free_fn pNtFreeVirtualMemory;
static volatile LONG running = 1, failures, rounds_alloc;
static HANDLE child_process;

static DWORD WINAPI allocator(void *arg) {
  (void)arg;
  while (running) {
    void *base = NULL;
    SIZE_T size = 0x1000;
    NTSTATUS status = pNtAllocateVirtualMemory(child_process, &base, 0, &size, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    if (status || !base) {
      if (InterlockedIncrement(&failures) == 1) printf("remote NtAllocateVirtualMemory: status %08lx\n", (unsigned long)status);
      Sleep(1);
      continue;
    }
    size = 0;
    status = pNtFreeVirtualMemory(child_process, &base, &size, MEM_RELEASE);
    if (status && InterlockedIncrement(&failures) == 1) printf("remote NtFreeVirtualMemory: status %08lx\n", (unsigned long)status);
    InterlockedIncrement(&rounds_alloc);
  }
  return 0;
}

int main(int argc, char **argv) {
  const char *mode = argc > 1 ? argv[1] : "suspended-alloc";
  char cmdline[MAX_PATH * 2];
  STARTUPINFOA si = {sizeof(si)};
  PROCESS_INFORMATION pi;
  HANDLE thread = NULL;
  DWORD code = 0;
  int i, suspended_alloc = !strcmp(mode, "suspended-alloc");
  int suspend = strcmp(mode, "alloc") != 0, alloc = strcmp(mode, "suspend") != 0 && !suspended_alloc;
  setvbuf(stdout, NULL, _IONBF, 0);
  if (!strcmp(mode, "child")) for (;;) SleepEx(INFINITE, TRUE);
  if (strcmp(mode, "alloc") && strcmp(mode, "suspend") && strcmp(mode, "both") && !suspended_alloc) {
    printf("FAIL x64-apcsuspend: usage: x64-apcsuspend [alloc|suspend|both|suspended-alloc]\n");
    return 2;
  }
  pNtAllocateVirtualMemory = (alloc_fn)(void *)GetProcAddress(GetModuleHandleA("ntdll.dll"), "NtAllocateVirtualMemory");
  pNtFreeVirtualMemory = (free_fn)(void *)GetProcAddress(GetModuleHandleA("ntdll.dll"), "NtFreeVirtualMemory");
  snprintf(cmdline, sizeof(cmdline), "\"%s\" child", argv[0]);
  if (!CreateProcessA(argv[0], cmdline, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)) {
    printf("FAIL x64-apcsuspend: CreateProcess: error %lu\n", GetLastError());
    return 1;
  }
  child_process = pi.hProcess;
  // No wait for the child to settle: the test starts while the child is still initialising, and the crash was there.
  if (getenv("APCSUSPEND_SETTLE_MS")) Sleep(atoi(getenv("APCSUSPEND_SETTLE_MS")));
  if (alloc) thread = CreateThread(NULL, 0, allocator, NULL, 0, NULL);
  for (i = 0; i < 1000; i++) {
    if (suspend) {
      DWORD r = SuspendThread(pi.hThread);
      if (r == (DWORD)-1) { printf("SuspendThread failed at round %d: error %lu\n", i, GetLastError()); failures++; break; }
      if (suspended_alloc) {
        void *base = NULL;
        SIZE_T size = 0x1000;
        NTSTATUS status = pNtAllocateVirtualMemory(child_process, &base, 0, &size, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
        if (status || !base) {
          printf("remote NtAllocateVirtualMemory at round %d: status %08lx\n", i, (unsigned long)status);
          failures++;
          ResumeThread(pi.hThread);
          break;
        }
        size = 0;
        pNtFreeVirtualMemory(child_process, &base, &size, MEM_RELEASE);
        rounds_alloc++;
      }
      else Sleep(1);
      ResumeThread(pi.hThread);
    }
    Sleep(1);
    if (GetExitCodeProcess(pi.hProcess, &code) && code != STILL_ACTIVE) break;
  }
  running = 0;
  if (thread) WaitForSingleObject(thread, 5000);
  GetExitCodeProcess(pi.hProcess, &code);
  printf("mode %s: %d rounds, %ld remote alloc/free pairs, %ld failures, child %s (exit %lx)\n", mode, i, rounds_alloc,
         failures, code == STILL_ACTIVE ? "running" : "dead", (unsigned long)code);
  TerminateProcess(pi.hProcess, 0);
  if (code != STILL_ACTIVE || failures) {
    printf("FAIL x64-apcsuspend %s\n", mode);
    return 1;
  }
  printf("PASS x64-apcsuspend\n");
  return 0;
}
