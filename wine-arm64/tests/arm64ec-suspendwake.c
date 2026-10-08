// A wake while every other thread is suspended (aoe2 patch 25, finding N3-F5), as AoE2DE's hang reporter does it:
// six threads contend for one SRW lock, so they are often inside WaitOnAddress or a wake; another thread suspends them
// all, then wakes on the lock's address from a helper thread. Without patch 25 a thread suspended inside the futex
// queue's spinlock kept it held, and the wake spun forever. Each round must finish within 3 s.
// Usage: <exe> [rounds] [hold]   hold: when a round sticks, stay alive for inspection instead of failing at once.
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

#if defined(__x86_64__) && !defined(__arm64ec__)
#define NAME "x64-suspendwake"  // the same source built for x64 (Makefile), under FEX
#else
#define NAME "arm64ec-suspendwake"
#endif

#define WORKERS 6
static SRWLOCK lock = SRWLOCK_INIT;
static volatile LONG stop, counter;

static DWORD WINAPI worker(void *arg) {
  (void)arg;
  while (!stop) {
    AcquireSRWLockExclusive(&lock);
    counter++;
    ReleaseSRWLockExclusive(&lock);
  }
  return 0;
}

static DWORD WINAPI waker(void *arg) {
  (void)arg;
  WakeByAddressAll((void *)&lock);
  WakeByAddressSingle((void *)&lock);
  return 0;
}

int main(int argc, char **argv) {
  int rounds = argc > 1 ? atoi(argv[1]) : 300, hold = argc > 2, i, j, stuck = 0;
  HANDLE w[WORKERS];
  DWORD t0 = GetTickCount();
  setvbuf(stdout, NULL, _IONBF, 0);
  for (j = 0; j < WORKERS; j++) w[j] = CreateThread(NULL, 0, worker, NULL, 0, NULL);
  Sleep(100);
  for (i = 0; i < rounds && !stuck; i++) {
    HANDLE h;
    for (j = 0; j < WORKERS; j++) SuspendThread(w[j]);
    h = CreateThread(NULL, 0, waker, NULL, 0, NULL);
    if (WaitForSingleObject(h, 3000) != WAIT_OBJECT_0) {
      printf("round %d: the wake did not return in 3 s with the workers suspended\n", i);
      stuck = 1;
      if (hold) Sleep(INFINITE);
    }
    CloseHandle(h);
    for (j = 0; j < WORKERS; j++) ResumeThread(w[j]);
    Sleep(1);
  }
  printf("%d rounds in %lu ms, %ld lock round trips\n", i, GetTickCount() - t0, counter);
  if (stuck) {
    printf("FAIL " NAME "\n");
    ExitProcess(1);  // threads may be stuck: leave without cleaning up
  }
  stop = 1;
  WaitForMultipleObjects(WORKERS, w, TRUE, 5000);
  printf("PASS " NAME "\n");
  return 0;
}
