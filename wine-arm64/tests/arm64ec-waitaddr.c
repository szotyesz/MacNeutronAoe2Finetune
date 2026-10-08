// WaitOnAddress semantics on the runtime (aoe2 patch 25, finding N3-F5): 4- and 8-byte waits go to the kernel's
// address wait queues (os_sync_wait_on_address), the other sizes and the addresses the kernel refuses to Wine's futex
// queues. Checks: every size; an immediate return when the value differs; timeouts, zero included; a single wake
// wakes one of two 4- or 8-byte waiters (at least one 1- or 2-byte waiter: those wait on their 4-byte word, so a
// single wake there wakes them all, which WaitOnAddress allows as spurious wakeups) and a wake-all every waiter; a
// misaligned 8-byte address; 4- and 8-byte waiters on one address; and SRW locks and condition variables under
// contention, which use WaitOnAddress, finish.
#include <windows.h>
#include <stdio.h>

#if defined(__x86_64__) && !defined(__arm64ec__)
#define NAME "x64-waitaddr"  // the same source built for x64 (Makefile), under FEX
#else
#define NAME "arm64ec-waitaddr"
#endif

static int fails;
#define CHECK(cond, ...) do { if (!(cond)) { printf("FAIL: " __VA_ARGS__); printf("\n"); fails++; } } while (0)

static __declspec(align(16)) volatile BYTE mem[64];
static volatile LONG woken;

struct waiter { volatile void *addr; SIZE_T size; DWORD timeout; BOOL ret; };

static DWORD WINAPI wait_thread(void *arg) {
  struct waiter *w = arg;
  ULONG64 cmp = 0;
  w->ret = WaitOnAddress(w->addr, &cmp, w->size, w->timeout);
  InterlockedIncrement(&woken);
  return 0;
}

static HANDLE start_waiter(struct waiter *w, volatile void *addr, SIZE_T size, DWORD timeout) {
  w->addr = addr; w->size = size; w->timeout = timeout; w->ret = -1;
  return CreateThread(NULL, 0, wait_thread, w, 0, NULL);
}

// 1. Every size: a waiter wakes when the value changes and it is woken; one whose value differs returns at once.
static void sizes(void) {
  static const SIZE_T list[] = { 1, 2, 4, 8 };
  for (unsigned int i = 0; i < 4; i++) {
    SIZE_T size = list[i];
    struct waiter w;
    ULONG64 one = 1;
    HANDLE h;
    ZeroMemory((void *)mem, sizeof(mem));
    h = start_waiter(&w, mem, size, 5000);
    Sleep(100);
    CHECK(WaitForSingleObject(h, 0) == WAIT_TIMEOUT, "size %zu: the waiter did not wait", size);
    memcpy((void *)mem, &one, size);
    WakeByAddressAll((void *)mem);
    CHECK(WaitForSingleObject(h, 2000) == WAIT_OBJECT_0 && w.ret == TRUE, "size %zu: not woken (ret %d)", size, w.ret);
    CloseHandle(h);
    {
      ULONG64 zero = 0;
      DWORD t0 = GetTickCount();
      BOOL r = WaitOnAddress((void *)mem, &zero, size, 2000);  // the value is 1: no wait
      CHECK(r == TRUE && GetTickCount() - t0 < 500, "size %zu: waited although the value differs", size);
    }
  }
}

// 2. Timeouts: 300 ms returns FALSE with ERROR_TIMEOUT after about 300 ms; 0 returns at once.
static void timeouts(void) {
  ULONG64 zero = 0;
  DWORD t0, dt;
  BOOL r;
  ZeroMemory((void *)mem, sizeof(mem));
  t0 = GetTickCount();
  r = WaitOnAddress((void *)mem, &zero, 4, 300);
  dt = GetTickCount() - t0;
  CHECK(!r && GetLastError() == ERROR_TIMEOUT && dt >= 250 && dt < 2000, "300 ms timeout: ret %d error %lu after %lu ms",
        r, GetLastError(), dt);
  t0 = GetTickCount();
  r = WaitOnAddress((void *)mem, &zero, 8, 0);
  CHECK(!r && GetLastError() == ERROR_TIMEOUT && GetTickCount() - t0 < 200, "zero timeout: ret %d", r);
}

// 3. WakeByAddressSingle wakes one of two waiters; WakeByAddressAll wakes every waiter.
static void single_and_all(SIZE_T size, volatile void *addr, const char *what) {
  struct waiter w[4];
  HANDLE h[4];
  ZeroMemory((void *)mem, sizeof(mem));
  woken = 0;
  for (int i = 0; i < 2; i++) h[i] = start_waiter(&w[i], addr, size, 5000);
  Sleep(200);
  WakeByAddressSingle((void *)addr);
  Sleep(300);
  CHECK(size >= 4 ? woken == 1 : woken >= 1, "%s: WakeByAddressSingle woke %ld of 2", what, woken);
  WakeByAddressSingle((void *)addr);
  CHECK(WaitForMultipleObjects(2, h, TRUE, 2000) == WAIT_OBJECT_0, "%s: the second waiter was not woken", what);
  for (int i = 0; i < 2; i++) CloseHandle(h[i]);
  woken = 0;
  for (int i = 0; i < 4; i++) h[i] = start_waiter(&w[i], addr, size, 5000);
  Sleep(200);
  WakeByAddressAll((void *)addr);
  CHECK(WaitForMultipleObjects(4, h, TRUE, 2000) == WAIT_OBJECT_0 && woken == 4, "%s: WakeByAddressAll woke %ld of 4",
        what, woken);
  for (int i = 0; i < 4; i++) CloseHandle(h[i]);
}

// 4. A 4-byte and an 8-byte waiter on one address: a wake-all reaches both.
static void mixed_sizes(void) {
  struct waiter w4, w8;
  HANDLE h[2];
  ZeroMemory((void *)mem, sizeof(mem));
  h[0] = start_waiter(&w4, mem, 4, 5000);
  Sleep(100);
  h[1] = start_waiter(&w8, mem, 8, 5000);
  Sleep(200);
  WakeByAddressAll((void *)mem);
  CHECK(WaitForMultipleObjects(2, h, TRUE, 2000) == WAIT_OBJECT_0, "mixed sizes: a waiter was not woken");
  CloseHandle(h[0]); CloseHandle(h[1]);
}

// 5. SRW locks and condition variables under contention: 8 threads, 20,000 rounds each, must finish.
static SRWLOCK srw = SRWLOCK_INIT;
static CONDITION_VARIABLE cv = CONDITION_VARIABLE_INIT;
static volatile LONG counter, turns;

static DWORD WINAPI srw_thread(void *arg) {
  (void)arg;
  for (int i = 0; i < 20000; i++) {
    AcquireSRWLockExclusive(&srw);
    counter++;
    if ((i & 63) == 0) {
      turns++;
      WakeAllConditionVariable(&cv);
      SleepConditionVariableSRW(&cv, &srw, 1, 0);
    }
    ReleaseSRWLockExclusive(&srw);
  }
  return 0;
}

static void contention(void) {
  HANDLE h[8];
  DWORD t0 = GetTickCount(), r;
  counter = 0;
  for (int i = 0; i < 8; i++) h[i] = CreateThread(NULL, 0, srw_thread, NULL, 0, NULL);
  r = WaitForMultipleObjects(8, h, TRUE, 30000);
  printf("contention: %ld increments in %lu ms\n", counter, GetTickCount() - t0);
  CHECK(r == WAIT_OBJECT_0 && counter == 8 * 20000, "contention: did not finish (counter %ld)", counter);
  for (int i = 0; i < 8; i++) CloseHandle(h[i]);
}

int main(void) {
  setvbuf(stdout, NULL, _IONBF, 0);
  sizes();
  timeouts();
  single_and_all(4, mem, "4 bytes");
  single_and_all(8, mem, "8 bytes");
  single_and_all(8, mem + 4, "8 bytes misaligned");
  single_and_all(2, mem, "2 bytes");
  mixed_sizes();
  contention();
  if (fails) {
    printf("FAIL " NAME " (%d)\n", fails);
    return 1;
  }
  printf("PASS " NAME "\n");
  return 0;
}
