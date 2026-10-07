#!/bin/sh
# Launches AoE2DE through Steam (steam://rungameid/813780) and watches it: a screenshot of the main display every 20 s and the
# game's processes, for <seconds>. Wrap it in aoe2/tests/verify-no-rosetta.sh. Usage: launch-watch.sh <run dir> <seconds>
out=$1 secs=$2
mkdir -p "$out"
date -u +%FT%TZ > "$out/start"
open "steam://rungameid/813780"
t=0
while [ $t -le "$secs" ]; do
  screencapture -x -t jpg "$out/shot-$(printf %03d $t).jpg" 2> /dev/null
  { echo "== t=$t"; ps -axo pid=,ppid=,flags=,%cpu=,rss=,comm= | grep -iE 'wine|AoE2|steam\.exe|macneutron|winedevice|explorer' | grep -v grep; } >> "$out/ps.txt"
  sleep 20; t=$((t + 20))
done
date -u +%FT%TZ > "$out/end"
