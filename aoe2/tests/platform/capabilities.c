/* Ported from Aoe2MacSteamNoRosetta tests/platform/capabilities.c at f37dfc2 (plan R2, N2). */
#include <errno.h>
#include <mach/mach.h>
#include <mach/mach_traps.h>
#include <os/arch/arm64.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;
extern uint64_t probe_custom_x18(void);

static int x18_test(void) {
    sigset_t all, saved;
    sigfillset(&all);
    if (pthread_sigmask(SIG_BLOCK, &all, &saved)) return 1;
    if (os_custom_x18_abi_enabled()) return 1;
    os_set_custom_x18_abi_enabled(true);
    int enabled = os_custom_x18_abi_enabled();
    uint64_t value;
    /* No macOS calls while custom mode is active except the two ABI APIs. */
    value = probe_custom_x18();
    os_set_custom_x18_abi_enabled(false);
    int disabled = !os_custom_x18_abi_enabled();
    int restored = pthread_sigmask(SIG_SETMASK, &saved, NULL) == 0;
    printf("x18: enabled=%d value=0x%llx restored=%d\n", enabled,
           (unsigned long long)value, disabled);
    return !(enabled && disabled && restored && value == 0x1234);
}

static void *tso_thread(void *result) {
    kern_return_t on = thread_set_x86_64_compat(1);
    kern_return_t off = thread_set_x86_64_compat(0);
    printf("TSO fresh thread: enable=%d disable=%d\n", on, off);
    *(int *)result = on != KERN_SUCCESS || off != KERN_SUCCESS;
    return NULL;
}

static int tso_test(void) {
    kern_return_t on = thread_set_x86_64_compat(1);
    pthread_t thread;
    int result = 1;
    int created = pthread_create(&thread, NULL, tso_thread, &result);
    int joined = created ? 1 : pthread_join(thread, NULL);
    kern_return_t off = thread_set_x86_64_compat(0);
    printf("TSO main thread: enable=%d disable=%d\n", on, off);
    return on != KERN_SUCCESS || off != KERN_SUCCESS || created || joined || result;
}

static int memory_test(void) {
    long page = sysconf(_SC_PAGESIZE);
    printf("page size: sysconf=%ld Mach=%lu\n", page, vm_page_size);
    if (page != 4096 || vm_page_size != 4096) return 1;
    /* PAGEZERO remapping at Windows' USER_SHARED_DATA address. */
    void *wanted = (void *)(uintptr_t)0x7ffe0000;
    void *p = mmap(wanted, 8192, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
    if (p == MAP_FAILED) { perror("low-address mmap"); return 1; }
    volatile unsigned char *bytes = p;
    bytes[0] = 0x42;
    bytes[4096] = 0x24;
    /* Exercise protection of an individual 4 KiB page within an 8 KiB region. */
    int protected = mprotect((char *)p + 4096, 4096, PROT_READ) == 0;
    int correct = bytes[0] == 0x42 && bytes[4096] == 0x24;
    printf("low mapping=%p individual 4 KiB protection=%d data=%d\n", p,
           protected, correct);
    int unmapped = munmap(p, 8192) == 0;
    return !(p == wanted && protected && correct && unmapped);
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc == 2) {
        if (!strcmp(argv[1], "memory")) return memory_test();
        if (!strcmp(argv[1], "x18")) return x18_test();
        if (!strcmp(argv[1], "tso")) return tso_test();
        return 1;
    }
    const char *cases[] = {"memory", "x18", "tso"};
    int failures = 0;
    for (unsigned i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i) {
        posix_spawnattr_t attr;
        int err = posix_spawnattr_init(&attr);
        if (err) { fprintf(stderr, "spawnattr init: %s\n", strerror(err)); return 1; }
        err = posix_spawnattr_set_4k_page_size_np(&attr);
        pid_t pid;
        char *args[] = {argv[0], (char *)cases[i], NULL};
        if (!err) err = posix_spawn(&pid, argv[0], NULL, &attr, args, environ);
        posix_spawnattr_destroy(&attr);
        if (err) {
            printf("FAIL %s: 4 KiB spawn: %s\n", cases[i], strerror(err));
            ++failures;
            continue;
        }
        int status = 0;
        pid_t waited;
        do { waited = waitpid(pid, &status, 0); } while (waited < 0 && errno == EINTR);
        int passed = waited == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0;
        printf("%s %s (exit=%d signal=%d)\n", passed ? "PASS" : "FAIL", cases[i],
               WIFEXITED(status) ? WEXITSTATUS(status) : -1,
               WIFSIGNALED(status) ? WTERMSIG(status) : 0);
        failures += !passed;
    }
    return failures ? 1 : 0;
}
