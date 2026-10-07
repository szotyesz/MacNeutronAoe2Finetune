#!/bin/sh
# Rule 3 of plan R2: no Rosetta process, ever. Runs <command> while sampling every process on the Mac, then fails if
#   - any sampled process had the kernel's P_TRANSLATED flag (0x20000, sys/proc.h: the process runs under Rosetta),
#   - oahd (Rosetta's daemon) ran, or
#   - any sampled executable that is a Mach-O file has no arm64/arm64e slice.
# Windows processes show as their Windows path or as a PE file (Wine names the process after the image): those are
# counted, not judged; their host process is the arm64 Wine loader. A process shorter than the sampling interval can be
# missed; without Rosetta installed it could not have been translated anyway, and the script says whether it is.
# Usage: verify-no-rosetta.sh <evidence dir> <command> [args...]   exit: the command's status, or 3 on a violation.
#        verify-no-rosetta.sh --self-test   the judge on fabricated samples: each violation kind must be caught.
# Writes <dir>/rosetta-samples.txt (pid flags comm), rosetta-classified.txt and rosetta-summary.txt.
set -u
interval=${ROSETTA_SAMPLE_INTERVAL:-0.2}

# judge <dir>: reads <dir>/rosetta-samples.txt, writes the classification and summary; returns 3 on a violation.
judge() {
dir=$1
samples="$dir/rosetta-samples.txt" classified="$dir/rosetta-classified.txt" summary="$dir/rosetta-summary.txt"
violations=0
n=$(wc -l < "$samples" | tr -d ' ')
# P_TRANSLATED: the kernel's own word on each live process.
translated=$(awk '{ f = $2; v = 0
  for (i = 1; i <= length(f); i++) v = v * 16 + index("0123456789abcdef", tolower(substr(f, i, 1))) - 1
  if (int(v / 131072) % 2 == 1) print }' "$samples" | sort -u)
[ -z "$translated" ] || violations=$((violations + 1))
oahd=$(awk '$3 ~ /(^|\/)oahd(-helper)?$/' "$samples" | sort -u)
[ -z "$oahd" ] || violations=$((violations + 1))
# Each distinct executable once.
: > "$classified"
awk '{ $1 = ""; $2 = ""; sub(/^  /, ""); print }' "$samples" | sort -u | while IFS= read -r p; do
  if [ ! -f "$p" ]; then c=name-only
  elif file -b "$p" | grep -q '^PE32'; then c=windows-image
  elif a=$(lipo -archs "$p" 2> /dev/null); then
    case " $a " in *" arm64 "* | *" arm64e "*) c=arm64 ;; *) c="NO-ARM64[$a]" ;; esac
  else c=not-mach-o
  fi
  printf '%s\t%s\n' "$c" "$p" >> "$classified"
done
noarm=$(grep '^NO-ARM64' "$classified" || true)
[ -z "$noarm" ] || violations=$((violations + 1))
if [ -d /Library/Apple/usr/libexec/oah ] && ls /Library/Apple/usr/libexec/oah | grep -qv '^RosettaLinux$'; then
  installed="installed ($(ls /Library/Apple/usr/libexec/oah | tr '\n' ' '))"
else
  installed="not installed"
fi
{
  echo "rosetta: $installed"
  echo "samples: $n distinct process rows (pid, flags, executable), sampled every ${interval} s"
  echo "executables: $(cut -f 1 "$classified" | sort | uniq -c | awk '{ printf "%s%s=%s", s, $2, $1; s = " " }')"
  echo "translated processes: $(echo "$translated" | grep -c . || true)"
  [ -z "$translated" ] || echo "$translated" | sed 's/^/  /'
  echo "oahd seen: $(echo "$oahd" | grep -c . || true)"
  [ -z "$noarm" ] || echo "$noarm" | sed 's/^/  /'
  if [ "$violations" = 0 ]; then echo "PASS verify-no-rosetta"; else echo "FAIL verify-no-rosetta: $violations violation kinds"; fi
} > "$summary"
cat "$summary"
[ "$violations" = 0 ] || return 3
}

if [ "${1:-}" = --self-test ]; then
  t=$(mktemp -d "${TMPDIR:-/tmp}/rosetta-self-test.XXXXXX") || exit 2
  trap 'rm -rf "$t"' EXIT
  printf 'int main(void) { return 0; }\n' > "$t/x.c"
  xcrun clang -arch x86_64 -o "$t/x86only" "$t/x.c" || { echo "FAIL self-test: can't build an x86_64 Mach-O"; exit 1; }
  ok=/bin/ls fails=0
  expect() {  # expect <name> <want status> <sample rows>
    mkdir -p "$t/$1"; printf '%s\n' "$3" > "$t/$1/rosetta-samples.txt"
    judge "$t/$1" > "$t/$1/out" && st=0 || st=$?
    if [ "$st" = "$2" ]; then echo "ok   $1"; else echo "FAIL $1: status $st, wanted $2"; cat "$t/$1/out"; fails=1; fi
  }
  expect clean 0 "1 4004 $ok
2 4004 C:\\windows\\system32\\wineboot.exe"
  expect translated 3 "1 4004 $ok
7 24004 $ok"
  expect oahd 3 "1 4004 $ok
9 4004 /usr/libexec/oahd"
  expect x86_64-only 3 "1 4004 $ok
5 4004 $t/x86only"
  [ "$fails" = 0 ] && echo "PASS verify-no-rosetta self-test" || exit 1
  exit 0
fi

[ $# -ge 2 ] || { echo "usage: verify-no-rosetta.sh <evidence dir> <command> [args...] | --self-test" >&2; exit 2; }
dir=$1; shift
mkdir -p "$dir" || exit 2
: > "$dir/rosetta-samples.txt"
stop="$dir/.rosetta-stop"; rm -f "$stop"
# Distinct rows only (pid, flags, executable), merged every 100 samples: a long run would otherwise write gigabytes.
( n=0; while [ ! -f "$stop" ]; do
    ps -axo pid=,flags=,comm= >> "$dir/rosetta-samples.txt"; n=$((n + 1))
    [ $((n % 100)) != 0 ] || LC_ALL=C sort -u -o "$dir/rosetta-samples.txt" "$dir/rosetta-samples.txt"
    sleep "$interval"
  done; LC_ALL=C sort -u -o "$dir/rosetta-samples.txt" "$dir/rosetta-samples.txt" ) &
sampler=$!
"$@"; status=$?
touch "$stop"; wait "$sampler"; rm -f "$stop"
judge "$dir" || exit 3
exit "$status"
