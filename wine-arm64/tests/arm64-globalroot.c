// A file opened through \\?\GLOBALROOT, as AoE2DE's anti-tamper opens its own executable and data files to verify
// them (aoe2 N3, finding N3-F1): it asks NtQueryVirtualMemory(MemoryMappedFilenameInformation) for the file mapped at
// its image base, puts \\?\GLOBALROOT in front of that NT name and opens it. GLOBALROOT is a link to the root of the
// object namespace, so \??\GLOBALROOT\??\X names the same file as \??\X. Without patch 23 Wine's ntdll recognised only
// \??\ and \DosDevices\ as DOS-namespace prefixes: the open failed with STATUS_OBJECT_NAME_NOT_FOUND, the game took
// that for tampering, left its code encrypted and crashed on it.
#include <windows.h>
#include <winternl.h>
#include <stdio.h>

#ifdef __x86_64__
#define NAME "x64-globalroot"  // the same source built for x64 (Makefile), under FEX
#else
#define NAME "arm64-globalroot"
#endif

typedef NTSTATUS (WINAPI *qvm_fn)(HANDLE, void *, ULONG, void *, SIZE_T, SIZE_T *);

static int open_ok(const WCHAR *path) {
  HANDLE h = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, 0, NULL);
  DWORD err = GetLastError(), size;
  if (h == INVALID_HANDLE_VALUE) {
    printf("open %ls: error %lu\n", path, err);
    return 0;
  }
  size = GetFileSize(h, NULL);
  CloseHandle(h);
  printf("open %ls: ok, %lu bytes\n", path, size);
  return size != INVALID_FILE_SIZE && size > 0;
}

int main(void) {
  qvm_fn qvm = (qvm_fn)(void *)GetProcAddress(GetModuleHandleA("ntdll.dll"), "NtQueryVirtualMemory");
  union { UNICODE_STRING us; BYTE buf[2048]; } mapped;
  WCHAR path[1100], win_ini[MAX_PATH], *p;
  SIZE_T len = 0;
  NTSTATUS st;
  int fails = 0;
  setvbuf(stdout, NULL, _IONBF, 0);

  // 2 = MemoryMappedFilenameInformation
  st = qvm(GetCurrentProcess(), GetModuleHandleW(NULL), 2, &mapped, sizeof(mapped), &len);
  if (st || !mapped.us.Length) {
    printf("FAIL " NAME ": MemoryMappedFilenameInformation: status %08lx\n", (unsigned long)st);
    return 1;
  }
  printf("mapped name: %.*ls\n", (int)(mapped.us.Length / sizeof(WCHAR)), mapped.us.Buffer);
  // As the game builds it: L"\\\\?\\GLOBALROOT" followed by the NT name.
  swprintf(path, ARRAYSIZE(path), L"\\\\?\\GLOBALROOT%.*ls", (int)(mapped.us.Length / sizeof(WCHAR)), mapped.us.Buffer);
  fails += !open_ok(path);

  // The same through the DosDevices name, and a plain file of the prefix with both GLOBALROOT forms.
  GetWindowsDirectoryW(win_ini, MAX_PATH);
  wcscat(win_ini, L"\\win.ini");
  swprintf(path, ARRAYSIZE(path), L"\\\\?\\GLOBALROOT\\??\\%ls", win_ini);
  fails += !open_ok(path);
  swprintf(path, ARRAYSIZE(path), L"\\\\?\\GLOBALROOT\\DosDevices\\%ls", win_ini);
  fails += !open_ok(path);
  // Controls that must keep working: the plain DOS path, and a GLOBALROOT path to a device.
  fails += !open_ok(win_ini);
  {
    HANDLE h = CreateFileW(L"\\\\?\\GLOBALROOT\\Device\\Null", GENERIC_READ, 0, NULL, OPEN_EXISTING, 0, NULL);
    printf("open \\\\?\\GLOBALROOT\\Device\\Null: %s (error %lu)\n", h == INVALID_HANDLE_VALUE ? "failed" : "ok",
           h == INVALID_HANDLE_VALUE ? GetLastError() : 0);
    if (h == INVALID_HANDLE_VALUE) fails++;
    else CloseHandle(h);
  }
  // A missing file through GLOBALROOT is still "not found", not something else.
  p = win_ini + wcslen(win_ini) - wcslen(L"win.ini");
  wcscpy(p, L"no-such-file.ini");
  swprintf(path, ARRAYSIZE(path), L"\\\\?\\GLOBALROOT\\??\\%ls", win_ini);
  if (CreateFileW(path, GENERIC_READ, 0, NULL, OPEN_EXISTING, 0, NULL) != INVALID_HANDLE_VALUE ||
      GetLastError() != ERROR_FILE_NOT_FOUND) {
    printf("missing file through GLOBALROOT: error %lu, wanted %ld\n", GetLastError(), ERROR_FILE_NOT_FOUND);
    fails++;
  }
  if (fails) {
    printf("FAIL " NAME ": %d\n", fails);
    return 1;
  }
  printf("PASS " NAME "\n");
  return 0;
}
