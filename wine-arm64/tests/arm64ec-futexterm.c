// A thread terminated by another while it waits in WaitOnAddress (aoe2 N3, finding N3-F4). AoE2DE's hang reporter
// kills its watchdog thread; FEX's ThreadTerm then frees the thread's emulator stack, where FEX's own mutex waits keep
// their RtlWaitOnAddress entries. Without patch 24 Wine left a terminated thread's entry linked in its futex queue:
//   1. a later WakeByAddressSingle woke the dead thread instead of a live waiter (a lost wakeup);
//   2. once the entry's memory was freed, the next wake on that queue read freed memory while holding the queue's
//      spinlock. Under FEX the access violation went to ResetToConsistentState, which takes ThreadCreationMutex, whose
//      release wakes waiters through the same queue: the thread spun on its own lock forever (the game's black screen).
// Check 2 frees the waiter's stack itself: the waiter runs on a fiber, whose stack is an ordinary allocation.
// Patch 24 covers ARM64EC processes (every x64 program under FEX, and this test's native lane); a pure ARM64 process
// still leaves the entry (its NtTerminateThread is a plain syscall): no emulator frees its memory there.
#include <windows.h>
#include <stdio.h>

#if defined(__x86_64__) && !defined(__arm64ec__)
#define NAME "x64-futexterm"  // the same source built for x64 (Makefile), under FEX
#else
#define NAME "arm64ec-futexterm"
#endif

static volatile LONG lost = 0, freed = 0;
static volatile LONG b_woken = 0;
static void *main_fiber, *wait_fiber;
static void *volatile wait_frame;

static DWORD WINAPI wait_forever(void *arg) {
  LONG cmp = 0;
  (void)arg;
  WaitOnAddress((void *)&lost, &cmp, sizeof(cmp), INFINITE);
  return 0;
}

static DWORD WINAPI wait_briefly(void *arg) {
  LONG cmp = 0;
  (void)arg;
  if (WaitOnAddress((void *)&lost, &cmp, sizeof(cmp), 3000)) InterlockedExchange(&b_woken, 1);
  return 0;
}

static VOID CALLBACK fiber_wait(void *arg) {
  LONG cmp = 0;
  (void)arg;
  wait_frame = &cmp;
  WaitOnAddress((void *)&freed, &cmp, sizeof(cmp), INFINITE);
  SwitchToFiber(main_fiber);
}

static DWORD WINAPI fiber_thread(void *arg) {
  (void)arg;
  main_fiber = ConvertThreadToFiber(NULL);
  wait_fiber = CreateFiber(64 * 1024, fiber_wait, NULL);
  if (!main_fiber || !wait_fiber) return 1;
  SwitchToFiber(wait_fiber);
  return 0;
}

static DWORD WINAPI wake_freed(void *arg) {
  (void)arg;
  WakeByAddressAll((void *)&freed);
  return 0;
}

// Starts a waiter, gives it time to queue itself, and terminates it.
static int kill_waiter(LPTHREAD_START_ROUTINE fn, const char *what) {
  HANDLE h = CreateThread(NULL, 0, fn, NULL, 0, NULL);
  if (!h) {
    printf("%s: CreateThread failed (%lu)\n", what, GetLastError());
    return 0;
  }
  Sleep(300);
  if (!TerminateThread(h, 0)) {
    printf("%s: TerminateThread failed (%lu)\n", what, GetLastError());
    return 0;
  }
  WaitForSingleObject(h, INFINITE);
  CloseHandle(h);
  return 1;
}

int main(void) {
  MEMORY_BASIC_INFORMATION mbi;
  HANDLE b, w;
  DWORD t0, r;
  int fails = 0;
  setvbuf(stdout, NULL, _IONBF, 0);

  // 1. A dead waiter must not take a live waiter's wakeup.
  if (!kill_waiter(wait_forever, "lost wakeup")) return 1;
  b = CreateThread(NULL, 0, wait_briefly, NULL, 0, NULL);
  Sleep(300);
  t0 = GetTickCount();
  WakeByAddressSingle((void *)&lost);
  WaitForSingleObject(b, INFINITE);
  CloseHandle(b);
  printf("lost wakeup: live waiter %s after %lu ms\n", b_woken ? "woken" : "not woken (timed out)", GetTickCount() - t0);
  if (!b_woken) fails++;

  // 2. A dead waiter's freed stack must not be read by the next wake.
  if (!kill_waiter(fiber_thread, "freed stack")) return 1;
  if (!wait_frame || !VirtualQuery(wait_frame, &mbi, sizeof(mbi))) {
    printf("freed stack: the fiber never waited\n");
    return 1;
  }
  if (!VirtualFree(mbi.AllocationBase, 0, MEM_RELEASE)) {
    printf("freed stack: VirtualFree(%p) failed (%lu)\n", mbi.AllocationBase, GetLastError());
    return 1;
  }
  w = CreateThread(NULL, 0, wake_freed, NULL, 0, NULL);
  r = WaitForSingleObject(w, 5000);
  printf("freed stack: wake after freeing the waiter's stack (%p) %s\n", mbi.AllocationBase,
         r == WAIT_OBJECT_0 ? "returned" : "did not return in 5 s");
  if (r != WAIT_OBJECT_0) {
    printf("FAIL " NAME "\n");
    ExitProcess(1);  // the waker is stuck: leave without waiting for it
  }
  CloseHandle(w);

  if (fails) {
    printf("FAIL " NAME "\n");
    return 1;
  }
  printf("PASS " NAME "\n");
  return 0;
}
