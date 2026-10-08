// The anti-tamper pattern AoE2DE's mod loading runs ~2 million times (aoe2 N3, finding F6): an illegal instruction
// traps, a vectored handler makes a trampoline page writable and executable, writes the next instruction into a
// slot there, makes the page execute-only again and continues in the slot, which jumps back to the instruction after
// the trap. Under FEX each protection change on the page throws away the code translated from it. Prints the time
// per trap for <rounds> traps (default 20000) with the protection changes, and without them (a page that stays RWX),
// on one thread and on four at once, and on one thread while <idle> other threads (default 64) that have run x64 code
// wait (the game has about 90); fails when a trap does not return where it should.
// Usage: x64-arxantrap.exe [rounds] [idle] [idleonly]   Prints "PASS x64-arxantrap" and "row <case> <us per trap>" lines.
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define TRAPS 64          // ud2s in a row in one trap chain
#define SLOT 64

struct chain {
  BYTE *code;             // TRAPS x (ud2), then ret
  BYTE *tramp;            // TRAPS slots: jmp qword [rip+0]; dq target
  BOOL reprotect;
  volatile LONG hits;
};

static struct chain chains[4];
static int fails;

static LONG CALLBACK handler(EXCEPTION_POINTERS *ep) {
  if (ep->ExceptionRecord->ExceptionCode != EXCEPTION_ILLEGAL_INSTRUCTION) return EXCEPTION_CONTINUE_SEARCH;
  for (int c = 0; c < 4; c++) {
    struct chain *ch = &chains[c];
    ULONG_PTR rip = ep->ContextRecord->Rip, off = rip - (ULONG_PTR)ch->code;
    if (!ch->code || rip < (ULONG_PTR)ch->code || off >= TRAPS * 2) continue;
    BYTE *slot = ch->tramp + (off / 2) * SLOT;
    ULONG64 back = rip + 2;
    DWORD old;
    if (ch->reprotect) VirtualProtect(ch->tramp, 0x1000, PAGE_EXECUTE_READWRITE, &old);
    slot[0] = 0xff; slot[1] = 0x25; memset(slot + 2, 0, 4);   // jmp qword [rip+0]
    memcpy(slot + 6, &back, 8);
    if (ch->reprotect) {
      VirtualProtect(ch->tramp, 0x1000, PAGE_EXECUTE_READ, &old);
      FlushInstructionCache(GetCurrentProcess(), slot, 14);
    }
    ch->hits++;
    ep->ContextRecord->Rip = (ULONG_PTR)slot;
    return EXCEPTION_CONTINUE_EXECUTION;
  }
  return EXCEPTION_CONTINUE_SEARCH;
}

static void setup(struct chain *ch, BOOL reprotect) {
  ch->code = VirtualAlloc(NULL, 0x1000, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
  for (int i = 0; i < TRAPS; i++) { ch->code[2 * i] = 0x0f; ch->code[2 * i + 1] = 0x0b; }  // ud2
  ch->code[2 * TRAPS] = 0xc3;                                                                 // ret
  ch->tramp = VirtualAlloc(NULL, 0x1000 * ((TRAPS * SLOT + 0xfff) / 0x1000), MEM_COMMIT | MEM_RESERVE,
                           PAGE_EXECUTE_READWRITE);
  ch->reprotect = reprotect;
  ch->hits = 0;
  FlushInstructionCache(GetCurrentProcess(), ch->code, 0x1000);
}

struct run { struct chain *ch; int rounds; };

static DWORD WINAPI run_chain(void *arg) {
  struct run *r = arg;
  void (*fn)(void) = (void (*)(void))r->ch->code;
  for (int i = 0; i < r->rounds / TRAPS; i++) fn();
  return 0;
}

static double measure(int threads, BOOL reprotect, int rounds) {
  HANDLE h[4];
  struct run runs[4];
  LARGE_INTEGER f, t0, t1;
  for (int t = 0; t < threads; t++) setup(&chains[t], reprotect);
  QueryPerformanceFrequency(&f);
  QueryPerformanceCounter(&t0);
  for (int t = 0; t < threads; t++) {
    runs[t].ch = &chains[t]; runs[t].rounds = rounds;
    h[t] = CreateThread(NULL, 0, run_chain, &runs[t], 0, NULL);
  }
  WaitForMultipleObjects(threads, h, TRUE, INFINITE);
  QueryPerformanceCounter(&t1);
  for (int t = 0; t < threads; t++) {
    int want = rounds / TRAPS * TRAPS;
    if (chains[t].hits != want) { printf("FAIL: thread %d: %ld traps, expected %d\n", t, chains[t].hits, want); fails++; }
    CloseHandle(h[t]);
    VirtualFree(chains[t].code, 0, MEM_RELEASE); VirtualFree(chains[t].tramp, 0, MEM_RELEASE);
    chains[t].code = NULL;
  }
  return (double)(t1.QuadPart - t0.QuadPart) * 1e6 / f.QuadPart / (rounds / TRAPS * TRAPS);
}

static HANDLE idle_event;

static DWORD WINAPI idle_thread(void *arg) {
  volatile int x = 0;
  (void)arg;
  for (int i = 0; i < 1000; i++) x += i;   // some x64 code, so FEX has set the thread up
  WaitForSingleObject(idle_event, INFINITE);
  return x;
}

int main(int argc, char **argv) {
  int rounds = argc > 1 ? atoi(argv[1]) : 20000, idle = argc > 2 ? atoi(argv[2]) : 64;
  HANDLE *idlers;
  setvbuf(stdout, NULL, _IONBF, 0);
  AddVectoredExceptionHandler(1, handler);
  if (argc <= 3 || strcmp(argv[3], "idleonly")) {
    printf("row reprotect-1thread %.2f\n", measure(1, TRUE, rounds));
    printf("row rwx-1thread %.2f\n", measure(1, FALSE, rounds));
    printf("row reprotect-4threads %.2f\n", measure(4, TRUE, rounds));
    printf("row rwx-4threads %.2f\n", measure(4, FALSE, rounds));
  }
  idle_event = CreateEventW(NULL, TRUE, FALSE, NULL);
  idlers = malloc(sizeof(HANDLE) * (idle ? idle : 1));
  for (int i = 0; i < idle; i++) idlers[i] = CreateThread(NULL, 0, idle_thread, NULL, 0, NULL);
  Sleep(500);
  printf("row reprotect-1thread-%didle %.2f\n", idle, measure(1, TRUE, rounds));
  SetEvent(idle_event);
  WaitForMultipleObjects(idle < 64 ? idle : 64, idlers, TRUE, INFINITE);
  for (int i = 64; i < idle; i += 64) WaitForMultipleObjects(idle - i < 64 ? idle - i : 64, idlers + i, TRUE, INFINITE);
  for (int i = 0; i < idle; i++) CloseHandle(idlers[i]);
  if (fails) { printf("FAIL x64-arxantrap (%d)\n", fails); return 1; }
  printf("PASS x64-arxantrap\n");
  return 0;
}
