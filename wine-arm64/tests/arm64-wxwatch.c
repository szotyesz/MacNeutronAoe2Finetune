// The W^X flip (patch 6) in a write-watched view (VirtualAlloc MEM_WRITE_WATCH, as GCs and some JITs use). After a run
// the host page is read-exec while Wine's own record still says PAGE_EXECUTE_READWRITE; the next write's fault must flip
// it back to read-write. Without patch 21 the fault is taken as "already writable" in a write-watch view and returns
// without changing anything, so the write faults again forever (found by aoe2 N2's A64-EXEC-ROLLBACK). This rewrites
// and runs one such page 10 times; the check step gives it a deadline.
#include <windows.h>
#include <stdio.h>

int main(void) {
  BYTE *page = VirtualAlloc(NULL, 0x1000, MEM_COMMIT | MEM_RESERVE | MEM_WRITE_WATCH, PAGE_EXECUTE_READWRITE);
  ULONG_PTR count = 1;
  void *written[1];
  DWORD granularity;
  int i;
  setvbuf(stdout, NULL, _IONBF, 0);  // a hang or crash keeps what was printed before it
  if (!page) {
    printf("FAIL arm64-wxwatch: VirtualAlloc: error %lu\n", GetLastError());
    return 1;
  }
  for (i = 1; i <= 10; i++) {
    DWORD code[2] = {0x52800000 | (i << 5), 0xd65f03c0};  // mov w0, #i; ret
    int got;
    memcpy(page, code, sizeof(code));
    FlushInstructionCache(GetCurrentProcess(), page, sizeof(code));
    got = ((int (*)(void))page)();
    printf("run %d returned %d\n", i, got);
    if (got != i) {
      printf("FAIL arm64-wxwatch: run %d returned %d\n", i, got);
      return 1;
    }
  }
  // The watch still works: the writes above are reported, then a reset clears them.
  if (GetWriteWatch(WRITE_WATCH_FLAG_RESET, page, 0x1000, written, &count, &granularity) || count != 1
      || written[0] != page) {
    printf("FAIL arm64-wxwatch: GetWriteWatch reported %lu pages\n", (unsigned long)count);
    return 1;
  }
  page[64] = 1;
  count = 1;
  if (GetWriteWatch(0, page, 0x1000, written, &count, &granularity) || count != 1) {
    printf("FAIL arm64-wxwatch: a write after the reset was not watched (%lu pages)\n", (unsigned long)count);
    return 1;
  }
  printf("PASS arm64-wxwatch\n");
  return 0;
}
