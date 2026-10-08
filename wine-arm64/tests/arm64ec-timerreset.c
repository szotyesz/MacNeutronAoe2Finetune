// Waitable timers and the threadpool's timer thread (aoe2 N3, finding F6): AoE2DE's start-up found ntdll's timer
// queue thread spinning (its NtWaitForMultipleObjects on its two timers returned at once, every time, about 8,000
// times a second, two NtSetTimer server calls each). Checks: a notification timer that fired is not signaled once
// SetWaitableTimer re-arms it, and fires again after the new due time; due times as far off as the timer thread
// asks for (absolute 0x7fffffffffffffff, and relative the uptime minus 0x7fffffffffffffff, which overflowed in
// wineserver: patch 26) don't fire; and an idle process whose one threadpool timer has fired, so that the timer thread
// has timers but none pending, spends under 100 ms of CPU time in 2 s.
// Usage: <exe>   Prints "PASS <name>" when every check holds.
#include <windows.h>
#include <stdio.h>

#if defined(__x86_64__) && !defined(__arm64ec__)
#define NAME "x64-timerreset"  // the same source built for x64 (Makefile), under FEX
#else
#define NAME "arm64ec-timerreset"
#endif

static int fails;
#define CHECK(cond, ...) do { if (!(cond)) { printf("FAIL: " __VA_ARGS__); printf("\n"); fails++; } } while (0)

static void set_rel(HANDLE timer, LONGLONG ms) {
  LARGE_INTEGER due;
  due.QuadPart = -ms * 10000;
  SetWaitableTimer(timer, &due, 0, NULL, NULL, FALSE);
}

// 1. A fired notification timer, re-armed, is unsignaled until its new due time.
static void rearm(void) {
  HANDLE timer = CreateWaitableTimerW(NULL, TRUE, NULL);
  DWORD t0, dt, r;
  set_rel(timer, 20);
  r = WaitForSingleObject(timer, 2000);
  CHECK(r == WAIT_OBJECT_0, "the 20 ms timer did not fire (%lu)", r);
  for (int i = 0; i < 3; i++) {
    set_rel(timer, 400);
    r = WaitForSingleObject(timer, 0);
    CHECK(r == WAIT_TIMEOUT, "round %d: signaled right after SetWaitableTimer re-armed it (%lu)", i, r);
    t0 = GetTickCount();
    r = WaitForSingleObject(timer, 3000);
    dt = GetTickCount() - t0;
    CHECK(r == WAIT_OBJECT_0 && dt >= 300, "round %d: the 400 ms timer returned %lu after %lu ms", i, r, dt);
  }
  // Two timers in one wait, as ntdll's timer thread waits: the fired one re-armed far off must not end the wait.
  {
    HANDLE pair[2] = { CreateWaitableTimerW(NULL, TRUE, NULL), timer };
    set_rel(pair[0], 60000);
    set_rel(timer, 10);
    r = WaitForMultipleObjects(2, pair, FALSE, 2000);
    CHECK(r == WAIT_OBJECT_0 + 1, "pair: the 10 ms timer did not end the wait (%lu)", r);
    set_rel(timer, 60000);
    t0 = GetTickCount();
    r = WaitForMultipleObjects(2, pair, FALSE, 300);
    CHECK(r == WAIT_TIMEOUT, "pair: both re-armed 60 s out, the wait returned %lu after %lu ms", r, GetTickCount() - t0);
    CloseHandle(pair[0]);
  }
  CloseHandle(timer);
}

// 2. The far due times ntdll's timer thread sets when a queue is empty never fire.
static void far_due(void) {
  HANDLE timer = CreateWaitableTimerW(NULL, TRUE, NULL);
  LARGE_INTEGER due, qpc;
  DWORD r;
  due.QuadPart = 0x7fffffffffffffffLL;  // absolute: an empty absolute queue
  SetWaitableTimer(timer, &due, 0, NULL, NULL, FALSE);
  r = WaitForSingleObject(timer, 300);
  CHECK(r == WAIT_TIMEOUT, "absolute 0x7fffffffffffffff fired (%lu)", r);
  QueryPerformanceCounter(&qpc);
  due.QuadPart = qpc.QuadPart - 0x7fffffffffffffffLL;  // relative: what update_timers() computes for MAXLONGLONG
  SetWaitableTimer(timer, &due, 0, NULL, NULL, FALSE);
  r = WaitForSingleObject(timer, 300);
  CHECK(r == WAIT_TIMEOUT, "relative %lld fired (%lu)", due.QuadPart, r);
  CloseHandle(timer);
}

// 3. A threadpool timer that has fired and still exists: the process stays idle.
static volatile LONG fired;
static void CALLBACK timer_cb(PTP_CALLBACK_INSTANCE inst, void *ctx, PTP_TIMER t) {
  (void)inst; (void)ctx; (void)t;
  InterlockedIncrement(&fired);
}

static ULONGLONG cpu_100ns(void) {
  FILETIME c, e, k, u;
  GetProcessTimes(GetCurrentProcess(), &c, &e, &k, &u);
  return ((ULONGLONG)k.dwHighDateTime << 32 | k.dwLowDateTime) + ((ULONGLONG)u.dwHighDateTime << 32 | u.dwLowDateTime);
}

static void idle_pool_timer(void) {
  PTP_TIMER t = CreateThreadpoolTimer(timer_cb, NULL, NULL);
  FILETIME due;
  ULARGE_INTEGER d;
  ULONGLONG c0, c1;
  d.QuadPart = (ULONGLONG)(-10LL * 10000);  // one shot, 10 ms
  due.dwLowDateTime = d.LowPart; due.dwHighDateTime = d.HighPart;
  SetThreadpoolTimer(t, &due, 0, 0);
  Sleep(300);
  CHECK(fired == 1, "the 10 ms threadpool timer fired %ld times", fired);
  c0 = cpu_100ns();
  Sleep(2000);
  c1 = cpu_100ns();
  printf("idle with a threadpool timer: %llu ms of CPU in 2 s\n", (c1 - c0) / 10000);
  CHECK((c1 - c0) / 10000 < 100, "the process used %llu ms of CPU in 2 s idle", (c1 - c0) / 10000);
  SetThreadpoolTimer(t, NULL, 0, 0);
  WaitForThreadpoolTimerCallbacks(t, TRUE);
  CloseThreadpoolTimer(t);
}

int main(void) {
  setvbuf(stdout, NULL, _IONBF, 0);
  rearm();
  far_due();
  idle_pool_timer();
  if (fails) {
    printf("FAIL " NAME " (%d)\n", fails);
    return 1;
  }
  printf("PASS " NAME "\n");
  return 0;
}
