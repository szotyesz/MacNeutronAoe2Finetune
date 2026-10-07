#!/bin/sh
# W^X audit (plan R2, N2): runs runtime.exe exec-wait on wine.app in each lane and, while it waits, reads its host
# process's mappings with vmmap. FAIL if any region's current protection is writable and executable at once. Regions
# whose maximum allows rwx are counted, not judged (macOS keeps max rwx on ordinary anonymous memory).
# Usage: wx-scan.sh <wine.app> <prefix arm64> <prefix x64> <runtime.exe arm64> <runtime.exe x64> <evidence dir>
# The x64 prefix must have FEX registered (m0.py's lanes do). Exit 0 only if both lanes pass.
set -u
[ $# = 6 ] || { echo "usage: wx-scan.sh <wine.app> <prefix arm64> <prefix x64> <exe arm64> <exe x64> <dir>" >&2; exit 2; }
app=$1 out=$6
mkdir -p "$out"
rc=0
scan() {  # scan <lane> <prefix> <exe>
  log="$out/$1-vmmap.txt"
  WINEPREFIX=$2 WINEMSYNC=1 WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;mscoree,mshtml=" \
    "$app/Contents/MacOS/wine" "$3" exec-wait > "$out/$1-stdout.txt" 2> "$out/$1-stderr.txt" &
  pid=$!
  i=0; while ! grep -q 'exec-wait READY' "$out/$1-stdout.txt" 2> /dev/null && [ $i -lt 600 ] && kill -0 $pid 2> /dev/null; do
    sleep 0.1; i=$((i + 1)); done
  if ! grep -q 'exec-wait READY' "$out/$1-stdout.txt"; then
    echo "FAIL wx-scan $1: exec-wait never got ready"; tail -3 "$out/$1-stderr.txt"; kill -9 $pid 2> /dev/null; rc=1; return
  fi
  vmmap -wide $pid > "$log" 2>&1
  kill $pid; wait $pid 2> /dev/null
  WINEPREFIX=$2 "$app/Contents/Resources/bin/wineserver" -k 2> /dev/null
  # Region lines carry cur/max as e.g. "r-x/rwx".
  regions=$(grep -cE ' [r-][w-][x-]/[r-][w-][x-] ' "$log")
  wx=$(grep -E ' [r-]wx/[r-][w-][x-] ' "$log" || true)
  maxwx=$(grep -cE ' [r-][w-][x-]/[r-]wx ' "$log")
  printf 'info wx-scan %s: %s regions, %s with max rwx, %s with current wx (%s)\n' "$1" "$regions" "$maxwx" \
    "$(echo "$wx" | grep -c . || true)" "$(head -1 "$out/$1-stdout.txt" | tr -d '\r')"
  [ "$regions" -gt 0 ] || { echo "FAIL wx-scan $1: vmmap listed no regions"; rc=1; return; }
  [ -z "$wx" ] || { echo "$wx" | head -5; echo "FAIL wx-scan $1: writable and executable regions"; rc=1; return; }
  echo "PASS wx-scan $1"
}
scan arm64 "$2" "$4"
scan x64 "$3" "$5"
exit $rc
