/* Ported from Aoe2MacSteamNoRosetta tests/exec-memory/host-vm-probe.c at f37dfc2 (plan R2, N2). */
/* EM-1 host experiment: identify which host protection operations for
 * anonymous executable memory fail on this macOS host, and with which errno.
 *
 * The parent spawns one isolated child per case, in a 4 KiB page child and in
 * a default (16 KiB) page child, and judges each child's status against the
 * case's oracle. A child fails if a required transition (RW->RX, RX->RW,
 * RW->RO, RO->RW) is refused or generated code returns a wrong value.
 * Simultaneous write/execute requests are observations, not requirements:
 * their result is printed as `case=... op=mprotect(RW->RWX) ok=0 errno=...`.
 * Fault-prone operations run in children so a fault reports a signal.
 */
#include <errno.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

#define PAGE4K 4096ULL
#define PAGE16K 16384ULL
#define RW (PROT_READ | PROT_WRITE)
#define RX (PROT_READ | PROT_EXEC)
#define RWX (PROT_READ | PROT_WRITE | PROT_EXEC)

/* ARM64: mov w0, #42; ret. */
static const uint32_t code42[2] = {0x52800540u, 0xd65f03c0u};

static void log_line(const char *id, const char *op, uint64_t size, int ok,
                     int code, const char *extra)
{
    printf("case=%s op=%s size=0x%llx ok=%d errno=%d(%s)%s%s\n", id, op,
           (unsigned long long)size, ok, code, code ? strerror(code) : "none",
           extra && *extra ? " " : "", extra ? extra : "");
}

static int dump_region(const char *id, const char *op, void *p)
{
    mach_vm_address_t addr = (mach_vm_address_t)p;
    mach_vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t obj;
    kern_return_t kr = mach_vm_region(mach_task_self(), &addr, &size,
                                      VM_REGION_BASIC_INFO_64,
                                      (vm_region_info_t)&info, &count, &obj);
    char extra[160];
    if (kr != KERN_SUCCESS)
    {
        snprintf(extra, sizeof(extra), "mach_vm_region kr=%d", kr);
        log_line(id, op, 0, 0, 0, extra);
        return 1;
    }
    snprintf(extra, sizeof(extra), "region prot=%u max=%u size=0x%llx",
             (unsigned)info.protection, (unsigned)info.max_protection,
             (unsigned long long)size);
    log_line(id, op, 0, 1, 0, extra);
    return 0;
}

static int run_code(const char *id, const char *op, void *p)
{
    __builtin___clear_cache((char *)p, (char *)p + sizeof(code42));
    int value = ((int (*)(void))p)();
    char extra[64];
    snprintf(extra, sizeof(extra), "exec=%d want=42", value);
    log_line(id, op, 0, value == 42, 0, extra);
    return value != 42;
}

static void *map_rw(const char *id, uint64_t size)
{
    void *p = mmap(NULL, size, RW, MAP_PRIVATE | MAP_ANON, -1, 0);
    log_line(id, "mmap(RW)", size, p != MAP_FAILED, p == MAP_FAILED ? errno : 0, "");
    return p == MAP_FAILED ? NULL : p;
}

/* Returns 1 when the operation succeeded. */
static int protect(const char *id, void *p, uint64_t size, int prot, const char *name)
{
    int ok = !mprotect(p, size, prot);
    char op[64];
    snprintf(op, sizeof(op), "mprotect(%s)", name);
    log_line(id, op, size, ok, ok ? 0 : errno, "");
    return ok;
}

/* Required transition: a refusal fails the case. */
static int require(const char *id, void *p, uint64_t size, int prot, const char *name)
{
    return !protect(id, p, size, prot, name);
}

/* Observed RWX request: success is recorded and the mapping inspected. */
static int observe_rwx(const char *id, void *p, uint64_t size, const char *name)
{
    if (protect(id, p, size, RWX, name))
        return dump_region(id, "region-after-rwx", p);
    return 0;
}

/* RW(write) -> RX -> exec -> RW -> RWX? -> RX -> exec -> RWX? -> RW */
static int ladder(const char *id, void *p, uint64_t size)
{
    int fail = 0;
    memcpy(p, code42, sizeof(code42));
    if ((fail += require(id, p, size, RX, "RW->RX"))) return fail;
    fail += dump_region(id, "region-after-rx", p);
    fail += run_code(id, "exec-rx", p);
    if ((fail += require(id, p, size, RW, "RX->RW"))) return fail;
    fail += observe_rwx(id, p, size, "RW->RWX");
    if ((fail += require(id, p, size, RX, "RW->RX"))) return fail;
    fail += run_code(id, "exec-rx2", p);
    fail += observe_rwx(id, p, size, "RX->RWX");
    fail += require(id, p, size, RW, "RX->RW");
    return fail;
}

static int matrix(int tso)
{
    uint64_t page = (uint64_t)sysconf(_SC_PAGESIZE);
    int fail = 0;
    printf("matrix pagesize=%llu mach=%lu\n", (unsigned long long)page,
           (unsigned long)vm_page_size);
    if (tso)
    {
        kern_return_t kr = thread_set_x86_64_compat(1);
        printf("tso enable kr=%d\n", kr);
        fail += kr != KERN_SUCCESS;
    }

    void *p = mmap(NULL, page, RWX, MAP_PRIVATE | MAP_ANON, -1, 0);
    log_line("A-mmap-rwx", "mmap(RWX)", page, p != MAP_FAILED,
             p == MAP_FAILED ? errno : 0, "");
    if (p != MAP_FAILED)
    {
        fail += dump_region("A-mmap-rwx", "region-after-mmap", p);
        munmap(p, page);
    }

    if ((p = map_rw("B-rw-to-rwx", page)))
    {
        fail += dump_region("B-rw-to-rwx", "region-after-mmap", p);
        fail += observe_rwx("B-rw-to-rwx", p, page, "RW->RWX");
        munmap(p, page);
    }
    else fail++;

    if ((p = map_rw("C-ladder", page))) { fail += ladder("C-ladder", p, page); munmap(p, page); }
    else fail++;

    if ((p = map_rw("D-16k-ladder", PAGE16K))) { fail += ladder("D-16k-ladder", p, PAGE16K); munmap(p, PAGE16K); }
    else fail++;

    /* Independent protection of an interior 4 KiB page. */
    if (page == PAGE4K && (p = map_rw("E-4k-inner", PAGE16K)))
    {
        char *inner = (char *)p + PAGE4K;
        memcpy(inner, code42, sizeof(code42));
        if (!(fail += require("E-4k-inner", inner, PAGE4K, RX, "RW->RX")))
        {
            fail += dump_region("E-4k-inner", "region-inner", inner);
            fail += dump_region("E-4k-inner", "region-before-inner", p);
            fail += run_code("E-4k-inner", "exec-inner", inner);
            fail += observe_rwx("E-4k-inner", inner, PAGE4K, "RX->RWX");
            *(volatile char *)p = 1; /* neighbouring RW page stays writable */
            log_line("E-4k-inner", "write-neighbour", PAGE4K, 1, 0, "");
        }
        munmap(p, PAGE16K);
    }
    else if (page == PAGE4K) fail++;

    printf("matrix failures=%d\n", fail);
    return fail != 0;
}

/* Write after RW->RO: the parent requires a protection fault. */
static int write_ro(void)
{
    uint64_t page = (uint64_t)sysconf(_SC_PAGESIZE);
    void *p = map_rw("W-ro", page);
    if (!p || require("W-ro", p, page, PROT_READ, "RW->RO")) return 1;
    *(volatile char *)p = 1;
    log_line("W-ro", "write", page, 0, 0, "write-succeeded-unexpectedly");
    return 1;
}

/* Write after a completed protection cycle must succeed.
 * ro: RW->RO->RW; rx: RW->RX->RW; exec: RW->RX->exec->RW. */
static int write_cycle(const char *variant)
{
    uint64_t page = (uint64_t)sysconf(_SC_PAGESIZE);
    int x = strcmp(variant, "ro") != 0;
    char id[32];
    snprintf(id, sizeof(id), "W-cycle-%s", variant);
    void *p = map_rw(id, page);
    if (!p) return 1;
    memcpy(p, code42, sizeof(code42));
    if (require(id, p, page, x ? RX : PROT_READ, x ? "RW->RX" : "RW->RO")) return 1;
    if (!strcmp(variant, "exec") && run_code(id, "exec", p)) return 1;
    if (require(id, p, page, RW, x ? "RX->RW" : "RO->RW")) return 1;
    if (dump_region(id, "region-after-rw", p)) return 1;
    *(volatile char *)p = 1;
    log_line(id, "write", page, 1, 0, "");
    return 0;
}

static int child(const char *mode)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    if (!strcmp(mode, "matrix")) return matrix(0);
    if (!strcmp(mode, "matrix-tso")) return matrix(1);
    if (!strcmp(mode, "write-ro")) return write_ro();
    if (!strncmp(mode, "cycle-", 6)) return write_cycle(mode + 6);
    fprintf(stderr, "unknown child mode %s\n", mode);
    return 2;
}

/* expected_signal 0 means exit 0 is required. */
static int spawn_case(const char *self, const char *mode, int four_k, int expected_signal)
{
    posix_spawnattr_t attr;
    pid_t pid;
    int status = 0, err = posix_spawnattr_init(&attr);
    char *args[] = {(char *)self, "--child", (char *)mode, NULL};
    printf("--- %s page=%s\n", mode, four_k ? "4k" : "default");
    if (!err && four_k) err = posix_spawnattr_set_4k_page_size_np(&attr);
    if (!err) err = posix_spawn(&pid, self, NULL, &attr, args, environ);
    posix_spawnattr_destroy(&attr);
    if (err)
    {
        printf("RESULT %s page=%s FAIL spawn errno=%d(%s)\n", mode,
               four_k ? "4k" : "default", err, strerror(err));
        return 1;
    }
    /* 30-second deadline; a hung child is killed and reported. */
    time_t deadline = time(NULL) + 30;
    pid_t waited;
    while ((waited = waitpid(pid, &status, WNOHANG)) == 0 && time(NULL) < deadline)
        usleep(10000);
    int timed_out = waited == 0;
    if (timed_out)
    {
        kill(pid, SIGKILL);
        waitpid(pid, &status, 0);
    }
    int pass = !timed_out && (expected_signal ?
        WIFSIGNALED(status) && WTERMSIG(status) == expected_signal :
        WIFEXITED(status) && WEXITSTATUS(status) == 0);
    printf("RESULT %s page=%s %s %s=%d%s\n", mode, four_k ? "4k" : "default",
           pass ? "PASS" : "FAIL", WIFSIGNALED(status) ? "signal" : "exit",
           WIFSIGNALED(status) ? WTERMSIG(status) : WEXITSTATUS(status),
           timed_out ? " timeout" : "");
    return !pass;
}

int main(int argc, char **argv)
{
    if (argc == 3 && !strcmp(argv[1], "--child")) return child(argv[2]);
    if (argc != 1)
    {
        fprintf(stderr, "usage: %s\n", argv[0]);
        return 2;
    }
    setvbuf(stdout, NULL, _IONBF, 0);
    static const struct { const char *mode; int expected_signal; } cases[] = {
        {"matrix", 0}, {"matrix-tso", 0}, {"write-ro", SIGBUS},
        {"cycle-ro", 0}, {"cycle-rx", 0}, {"cycle-exec", 0},
    };
    int failures = 0;
    for (int four_k = 1; four_k >= 0; four_k--)
        for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++)
            failures += spawn_case(argv[0], cases[i].mode, four_k, cases[i].expected_signal);
    printf("host-vm-probe failures=%d\n", failures);
    return failures != 0;
}
