#!/bin/sh
# x18 signal stress (plan R2 N2, R1 review finding R1-X18-RACE). runtime.exe x18-stress runs 4 workers through
# syscalls (SwitchToThread), unix calls (GetSystemTimePreciseAsFileTime) and exceptions (raised and access-violation)
# in a loop, each iteration checking NtCurrentTeb() (on ARM64 it reads x18) against its TEB, while the main thread
# suspends each worker and, on ARM64, checks the context's x18. Meanwhile sigpump sends SIGUSR1 to the host process
# every <interval> µs: Wine's usr1_handler (x18-wrapped) saves the context, asks the server and restores it, so signal
# entry lands at arbitrary points, the PE<->unix boundaries included. Passes on "M0 x18-stress PASS", exit 0, signals
# delivered, no unhandled exception, no 'x18:' error line and no new crash report.
# Usage: run.sh <wine.app> <prefix> <runtime.exe> <lane> <seconds> <interval µs> <evidence dir>
set -u
[ $# = 7 ] || { echo "usage: run.sh <wine.app> <prefix> <runtime.exe> <lane> <seconds> <interval us> <dir>" >&2; exit 2; }
app=$1 prefix=$2 exe=$3 lane=$4 secs=$5 interval=$6 out=$7
mkdir -p "$out"
pump="$out/sigpump"
[ -x "$pump" ] || xcrun clang -O1 -Wall -Werror -o "$pump" "$(dirname "$0")/sigpump.c" || exit 2
ips_before=$(ls "$HOME"/Library/Logs/DiagnosticReports/wine-*.ips 2> /dev/null || true)
WINEPREFIX=$prefix WINEMSYNC=1 WINEDEBUG=err+all M0_STRESS_SECONDS=$secs \
  WINEDLLOVERRIDES="winedbg.exe=d;mscoree,mshtml=" "$app/Contents/MacOS/wine" "$exe" x18-stress \
  > "$out/$lane-stdout.txt" 2> "$out/$lane-stderr.txt" &
pid=$!
i=0; while ! grep -q 'x18-stress READY' "$out/$lane-stdout.txt" 2> /dev/null && [ $i -lt 600 ] && kill -0 $pid 2> /dev/null; do
  sleep 0.1; i=$((i + 1)); done
"$pump" $pid 30 "$interval" $((secs + 30)) > "$out/$lane-sigpump.txt"   # 30 = SIGUSR1
wait $pid; rc=$?
WINEPREFIX=$prefix "$app/Contents/Resources/bin/wineserver" -k 2> /dev/null
sleep 2  # ReportCrash writes from the corpse after the exit
ips_new=$( (ls "$HOME"/Library/Logs/DiagnosticReports/wine-*.ips 2> /dev/null || true) | grep -vxF "$ips_before" || true)
stats=$(tr -d '\r' < "$out/$lane-stdout.txt" | grep '^M0 x18-stress seconds=' || true)
sent=$(sed -n 's/^sigpump sent=\([0-9]*\).*/\1/p' "$out/$lane-sigpump.txt")
why=
tr -d '\r' < "$out/$lane-stdout.txt" | grep -qx 'M0 x18-stress PASS' || why="no PASS line"
[ "$rc" = 0 ] || why="${why:+$why; }exit $rc"
[ "${sent:-0}" -gt 0 ] || why="${why:+$why; }no signal sent"
! grep -q 'Unhandled' "$out/$lane-stderr.txt" || why="${why:+$why; }unhandled exception"
! grep -q 'x18:' "$out/$lane-stderr.txt" || why="${why:+$why; }x18 error: $(grep -m1 'x18:' "$out/$lane-stderr.txt")"
[ -z "$ips_new" ] || why="${why:+$why; }crash report $ips_new"
echo "info x18-signal $lane: $stats; $(cat "$out/$lane-sigpump.txt") (every $interval us)"
if [ -z "$why" ]; then echo "PASS x18-signal $lane"; else grep -m3 FAIL "$out/$lane-stderr.txt"; echo "FAIL x18-signal $lane: $why"; exit 1; fi
