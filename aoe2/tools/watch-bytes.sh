#!/bin/sh
# Starts the game through replay-launch.py and, while AoE2DE_s.exe's host process lives, reads the 8 bytes at
# 0x142B9A04C with lldb (attach, read, detach) as often as that allows. Usage: watch-bytes.sh <out dir> [KEY=VALUE...] A side effect worth knowing:
# each attach pauses the process, and after the crash it then hangs in "starting debugger" with its memory intact.
out=$1; shift
mkdir -p "$out"; : > "$out/bytes.txt"
python3 "$(dirname "$0")/replay-launch.py" "$out" 60 "$@" > "$out/replay.txt" 2>&1 &
rp=$!
pid=
for i in $(seq 1 100); do
  pid=$(ps -axo pid=,comm= | awk '/AoE2DE_s\.exe/ { print $1; exit }')
  [ -n "$pid" ] && break; sleep 0.1
done
echo "pid $pid" >> "$out/bytes.txt"
end=$(( $(date +%s) + 30 ))
while [ "$(date +%s)" -lt "$end" ]; do
  pid=$(ps -axo pid=,comm= | awk '/AoE2DE_s\.exe/ { print $1; exit }')
  [ -n "$pid" ] || { kill -0 "$rp" 2> /dev/null || break; sleep 0.05; continue; }
  t=$(python3 -c 'import time; print(f"{time.time():.2f}")')
  b=$(lldb -b -p "$pid" -o "memory read -s1 -c8 -fx 0x142B9A04C" -o "detach" 2>&1 | grep -E '^0x142b9a04c|error' | head -1)
  echo "$t $pid $b" >> "$out/bytes.txt"
done
wait $rp
cat "$out/replay.txt"
