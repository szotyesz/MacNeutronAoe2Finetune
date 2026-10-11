// Code that keeps being rewritten in private memory, as AoE2DE's anti-tamper does with its pool of relocated
// instructions: FEX compiles such code into pool buffers of its own (MacNeutron FEX patch, MACNEUTRON_POOL_BUFFER_MB),
// which fill and are replaced while threads run code from them.
//
// A 16 MB read-write-execute region holds 32-byte slots. A slot either returns imm + ecx, or loads imm into eax and
// jumps to another slot that adds ecx and returns, so calls go from the image into the region and back, and from slot
// to slot. Four worker threads call random slots and check each result. A rewriter thread regenerates one 1 MB chunk
// at a time with new values and new jump targets, between VirtualProtect calls (the chunk's lock keeps workers out
// meanwhile). Every slot of a chunk gets called after a rewrite, so the region's code is compiled again and again.
// Usage: x64-poolchurn [seconds]  (default 20). PASS when every call returned what its slot computes.
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

#define REGION_SIZE (16u << 20)
#define CHUNK_SIZE (1u << 20)
#define SLOT_SIZE 32u
#define CHUNKS (REGION_SIZE / CHUNK_SIZE)
#define SLOTS_PER_CHUNK (CHUNK_SIZE / SLOT_SIZE)
#define WORKERS 4

static BYTE *region;
static SRWLOCK chunk_lock[CHUNKS];
static int value[CHUNKS][SLOTS_PER_CHUNK];  // what each slot returns for ecx = 0
static volatile LONG stop, failures;
static volatile LONG64 calls, rewrites;

static ULONG rng_next(ULONG *state) {
  *state = *state * 1103515245u + 12345u;
  return *state >> 8;
}

// Writes the slots of chunk c. Slot kinds: 0 = mov eax, imm; add eax, ecx; ret
// 1 = mov eax, imm; jmp <adder slot>, where the chunk's slot 0 is always an adder: add eax, ecx; ret
static void write_chunk(unsigned int c, ULONG *state) {
  BYTE *base = region + (size_t)c * CHUNK_SIZE;
  BYTE *adder = base;
  adder[0] = 0x01; adder[1] = 0xC8;  // add eax, ecx
  adder[2] = 0xC3;                   // ret
  value[c][0] = 0;
  for (unsigned int i = 1; i < SLOTS_PER_CHUNK; i++) {
    BYTE *slot = base + (size_t)i * SLOT_SIZE;
    int imm = (int)(rng_next(state) & 0xFFFFFF);
    slot[0] = 0xB8;  // mov eax, imm32
    memcpy(slot + 1, &imm, 4);
    if (rng_next(state) & 1) {
      slot[5] = 0x01; slot[6] = 0xC8;  // add eax, ecx
      slot[7] = 0xC3;                  // ret
    } else {
      int rel = (int)(adder - (slot + 10));
      slot[5] = 0xE9;  // jmp rel32 to the adder
      memcpy(slot + 6, &rel, 4);
    }
    for (unsigned int j = 10; j < SLOT_SIZE; j++) slot[j] = (BYTE)rng_next(state);  // junk, as in the game's pool
    value[c][i] = imm;
  }
}

static DWORD WINAPI rewriter(void *arg) {
  ULONG state = 0x1234567;
  (void)arg;
  while (!stop) {
    for (unsigned int c = 0; c < CHUNKS && !stop; c++) {
      DWORD old;
      AcquireSRWLockExclusive(&chunk_lock[c]);
      VirtualProtect(region + (size_t)c * CHUNK_SIZE, CHUNK_SIZE, PAGE_READWRITE, &old);
      write_chunk(c, &state);
      VirtualProtect(region + (size_t)c * CHUNK_SIZE, CHUNK_SIZE, PAGE_EXECUTE_READWRITE, &old);
      FlushInstructionCache(GetCurrentProcess(), region + (size_t)c * CHUNK_SIZE, CHUNK_SIZE);
      ReleaseSRWLockExclusive(&chunk_lock[c]);
      InterlockedIncrement64(&rewrites);
      Sleep(20);
    }
  }
  return 0;
}

static DWORD WINAPI worker(void *arg) {
  ULONG state = (ULONG)(ULONG_PTR)arg * 7919u + 1;
  while (!stop) {
    unsigned int c = rng_next(&state) % CHUNKS;
    AcquireSRWLockShared(&chunk_lock[c]);
    // Sweep a stretch of the chunk so that most of it gets compiled after each rewrite.
    unsigned int first = 1 + rng_next(&state) % (SLOTS_PER_CHUNK - 512);
    for (unsigned int i = first; i < first + 512; i++) {
      int (*fn)(int) = (int (*)(int))(region + (size_t)c * CHUNK_SIZE + (size_t)i * SLOT_SIZE);
      int x = (int)(rng_next(&state) & 0xFFFF);
      int r = fn(x);
      if (r != value[c][i] + x) {
        if (InterlockedIncrement(&failures) <= 10)
          printf("FAIL: chunk %u slot %u returned %d, expected %d\n", c, i, r, value[c][i] + x);
      }
    }
    ReleaseSRWLockShared(&chunk_lock[c]);
    InterlockedAdd64(&calls, 512);
  }
  return 0;
}

int main(int argc, char **argv) {
  DWORD seconds = argc > 1 ? (DWORD)atoi(argv[1]) : 20;
  HANDLE threads[WORKERS + 1];
  ULONG state = 42;
  DWORD t0;

  setvbuf(stdout, NULL, _IONBF, 0);
  region = VirtualAlloc(NULL, REGION_SIZE, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
  if (!region) {
    printf("FAIL x64-poolchurn: VirtualAlloc %lu\n", GetLastError());
    return 1;
  }
  for (unsigned int c = 0; c < CHUNKS; c++) {
    InitializeSRWLock(&chunk_lock[c]);
    write_chunk(c, &state);
  }
  FlushInstructionCache(GetCurrentProcess(), region, REGION_SIZE);

  t0 = GetTickCount();
  threads[0] = CreateThread(NULL, 0, rewriter, NULL, 0, NULL);
  for (unsigned int i = 0; i < WORKERS; i++) threads[i + 1] = CreateThread(NULL, 0, worker, (void *)(ULONG_PTR)(i + 1), 0, NULL);
  Sleep(seconds * 1000);
  stop = 1;
  if (WaitForMultipleObjects(WORKERS + 1, threads, TRUE, 30000) != WAIT_OBJECT_0) {
    printf("FAIL x64-poolchurn: the threads did not finish\n");
    return 1;
  }
  printf("%lld calls, %lld chunk rewrites in %lu ms, %ld wrong results\n", calls, rewrites, GetTickCount() - t0, failures);
  if (failures) {
    printf("FAIL x64-poolchurn\n");
    return 1;
  }
  printf("PASS x64-poolchurn\n");
  return 0;
}
