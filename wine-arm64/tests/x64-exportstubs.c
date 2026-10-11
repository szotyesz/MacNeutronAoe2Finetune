// How Wine's ARM64EC system DLLs look to x64 code at their exports (aoe2 HANDOFF §4 item 5: AoE2DE quits a few minutes
// after start). lld gives an ARM64EC DLL's exports that are imports from another DLL a bare x64 jump, FF 25 disp32
// ("jmp [rip+disp32]"), which looks like an inline hook to code that checks API entry points; x64 Windows DLLs forward
// with 48 FF 25 disp32, the REX.W form. For kernel32, kernelbase, ntdll, user32 and advapi32 this counts the exports
// that start with each form, Windows' fast-forward sequence, or anything else, and lists the first bare ones. Every
// 48 FF 25 stub's slot must point into a loaded module, and a few kernel32 calls must still work.
// PASS when no export starts with a bare FF 25.
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <intrin.h>

static const unsigned char ffs_seq[] = {0x48, 0x8b, 0xc4, 0x48, 0x89, 0x58, 0x20, 0x55, 0x5d, 0xe9};

static int check_module(const char *name, int *bad_slots)
{
  HMODULE mod = LoadLibraryA(name);
  unsigned char *base = (unsigned char *)mod;
  IMAGE_NT_HEADERS64 *nt;
  IMAGE_DATA_DIRECTORY *dir;
  IMAGE_EXPORT_DIRECTORY *exp;
  DWORD *funcs, *names, i, j, total = 0, bare = 0, rex = 0, fast = 0, other = 0, listed = 0;
  WORD *ords;

  if (!mod) { printf("%s: LoadLibrary failed %lu\n", name, GetLastError()); return 1; }
  nt = (IMAGE_NT_HEADERS64 *)(base + ((IMAGE_DOS_HEADER *)base)->e_lfanew);
  dir = &nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT];
  exp = (IMAGE_EXPORT_DIRECTORY *)(base + dir->VirtualAddress);
  funcs = (DWORD *)(base + exp->AddressOfFunctions);
  names = (DWORD *)(base + exp->AddressOfNames);
  ords = (WORD *)(base + exp->AddressOfNameOrdinals);
  for (i = 0; i < exp->NumberOfFunctions; i++) {
    unsigned char *p;
    const char *fname = NULL;
    if (!funcs[i]) continue;
    if (funcs[i] >= dir->VirtualAddress && funcs[i] < dir->VirtualAddress + dir->Size) continue;  // forwarder string
    p = base + funcs[i];
    total++;
    if (p[0] == 0xff && p[1] == 0x25) {
      bare++;
      for (j = 0; j < exp->NumberOfNames; j++) if (ords[j] == i) fname = (const char *)(base + names[j]);
      if (listed++ < 10) printf("%s: bare FF 25 at %s (+0x%lx)\n", name, fname ? fname : "?", funcs[i]);
    } else if (p[0] == 0x48 && p[1] == 0xff && p[2] == 0x25) {
      void *target = *(void **)(p + 7 + *(int *)(p + 3));
      HMODULE owner;
      rex++;
      if (!target || !GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                                         (const char *)target, &owner)) {
        for (j = 0; j < exp->NumberOfNames; j++) if (ords[j] == i) fname = (const char *)(base + names[j]);
        if ((*bad_slots)++ < 10) printf("%s: 48 FF 25 at %s jumps through a slot holding %p, in no module\n", name,
                                        fname ? fname : "?", target);
      }
    } else if (!memcmp(p, ffs_seq, sizeof(ffs_seq))) fast++;
    else other++;
  }
  printf("%s: exports %lu, bare FF 25 %lu, 48 FF 25 %lu, fast-forward %lu, other %lu\n", name, total, bare, rex, fast,
         other);
  return bare != 0;
}

int main(void)
{
  static const char *mods[] = {"kernel32.dll", "kernelbase.dll", "ntdll.dll", "user32.dll", "advapi32.dll"};
  HMODULE k32 = GetModuleHandleA("kernel32.dll");
  DWORD (WINAPI *get_pid)(void) = (void *)GetProcAddress(k32, "GetCurrentProcessId");
  DWORD (WINAPI *get_tid)(void) = (void *)GetProcAddress(k32, "GetCurrentThreadId");
  void (WINAPI *set_err)(DWORD) = (void *)GetProcAddress(k32, "SetLastError");
  DWORD (WINAPI *get_err)(void) = (void *)GetProcAddress(k32, "GetLastError");
  void (WINAPI *sleep)(DWORD) = (void *)GetProcAddress(k32, "Sleep");
  int (WINAPI *lstrlen_w)(const WCHAR *) = (void *)GetProcAddress(k32, "lstrlenW");
  int bad = 0, bad_slots = 0, calls_ok;
  unsigned i;

  for (i = 0; i < sizeof(mods) / sizeof(mods[0]); i++) bad |= check_module(mods[i], &bad_slots);
  sleep(0);
  set_err(1234);
  calls_ok = get_err() == 1234 && get_pid() == (DWORD)__readgsqword(0x40)  /* TEB ClientId */
             && get_tid() == (DWORD)__readgsqword(0x48) && lstrlen_w(L"abc") == 3;
  printf("calls through kernel32: %s\n", calls_ok ? "ok" : "WRONG");
  if (bad_slots) printf("48 FF 25 stubs with a slot outside every module: %d\n", bad_slots);
  if (bad || bad_slots || !calls_ok) { printf("FAIL x64-exportstubs\n"); return 1; }
  printf("PASS x64-exportstubs\n");
  return 0;
}
