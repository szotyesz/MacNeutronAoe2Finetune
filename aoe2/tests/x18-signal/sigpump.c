/* Sends a signal to a process at a fixed rate until it exits or a duration ends (aoe2 N2, x18 signal stress).
 * Usage: sigpump <pid> <signal> <interval µs> <seconds>. Prints "sigpump sent=<n> ended=<exited|duration>". */
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    if (argc != 5) { fprintf(stderr, "usage: sigpump <pid> <signal> <interval us> <seconds>\n"); return 2; }
    pid_t pid = (pid_t)atoi(argv[1]);
    int sig = atoi(argv[2]);
    useconds_t interval = (useconds_t)atoi(argv[3]);
    time_t end = time(NULL) + atoi(argv[4]);
    unsigned long sent = 0;
    const char *ended = "duration";
    while (time(NULL) < end) {
        if (kill(pid, sig)) { ended = errno == ESRCH ? "exited" : "error"; break; }
        sent++;
        if (interval) usleep(interval);
    }
    printf("sigpump sent=%lu ended=%s\n", sent, ended);
    return 0;
}
