#!/bin/sh
# P0 host probes on this Mac (plan R2, N2): the companion repository's test-platform.sh and test-host-vm.sh, ported.
# platform/capabilities.c: 4K spawn, the low map at 0x7ffe0000, 4K protection, the x18 ABI toggle and per-thread TSO.
# exec-memory/host-vm-probe.c: which host protection changes anonymous memory accepts (RW<->RX required; RWX observed).
# Both are built with the loader's layout (x86_64 layout emulation, 4 GB PAGEZERO) and ad-hoc signed with the managed
# cross-architecture entitlement, as wine.app's loader is in ad-hoc mode; P0_ENTITLEMENT=unmanaged signs with
# com.apple.developer.cross-architecture-support-unmanaged instead (the name P0 used on macOS 26.6.2), and
# P0_ENTITLEMENT=loader with wine-arm64/wine-adhoc.entitlements, the loader's own set (allow-jit and
# allow-unsigned-executable-memory too), which is what decides whether wine.app can map W and X together.
# Usage: p0.sh   Evidence: $AOE2_WORK_ROOT/n2/p0-<UTC stamp>/ (default ~/aoe2-poc-work). Exit 0 only if both pass.
set -eu
T="$(cd "$(dirname "$0")" && pwd)"
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || { echo "p0: run natively on Apple Silicon" >&2; exit 2; }
[ -n "${DEVELOPER_DIR:-}" ] || ! [ -d /Applications/Xcode.app ] || export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
OUT="${AOE2_WORK_ROOT:-$HOME/aoe2-poc-work}/n2/p0-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT"
case ${P0_ENTITLEMENT:-managed} in
  managed) ent=com.apple.developer.cross-architecture-support ;;
  unmanaged) ent=com.apple.developer.cross-architecture-support-unmanaged ;;
  loader) ent=loader ;;
  *) echo "p0: P0_ENTITLEMENT is managed, unmanaged or loader" >&2; exit 2 ;;
esac
if [ "$ent" = loader ]; then
  cp "$T/../../wine-arm64/wine-adhoc.entitlements" "$OUT/entitlements.plist"
else
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>%s</key><true/></dict></plist>\n' "$ent" > "$OUT/entitlements.plist"
fi
{
  printf 'Host: macOS %s (%s), %s\nSDK: %s\n' "$(sw_vers -productVersion)" "$(sw_vers -buildVersion)" \
    "$(sysctl -n hw.model)" "$(xcrun --show-sdk-version)"
  csrutil status
  printf 'Boot arguments: %s\nEntitlement: %s\n' "$(sysctl -n kern.bootargs)" "$ent"
} | tee "$OUT/host.txt"
build() {  # build <name> <sources...>
  n=$1; shift
  xcrun clang -arch arm64 -mmacosx-version-min=26.5 -Wall -Wextra -Werror "$@" -pthread \
    -Wl,-x86_64_layout_emulation -Wl,-pagezero_size,0x100000000 -o "$OUT/$n"
  codesign --force --sign - --options runtime --entitlements "$OUT/entitlements.plist" "$OUT/$n" 2> /dev/null
  codesign --verify --strict "$OUT/$n"
}
build capabilities "$T/platform/capabilities.c" "$T/platform/x18.S"
build host-vm-probe "$T/exec-memory/host-vm-probe.c"
shasum -a 256 "$T/platform/capabilities.c" "$T/platform/x18.S" "$T/exec-memory/host-vm-probe.c" "$OUT/capabilities" \
  "$OUT/host-vm-probe" > "$OUT/sha256.txt"
rc=0
echo "--- capabilities"
"$OUT/capabilities" 2>&1 | tee "$OUT/capabilities.log"
grep -q '^FAIL' "$OUT/capabilities.log" && rc=1
[ "$(grep -c '^PASS' "$OUT/capabilities.log")" = 3 ] || rc=1
echo "--- host-vm-probe"
"$OUT/host-vm-probe" > "$OUT/host-vm-probe.log" 2>&1 || rc=1
grep -E '^(RESULT|host-vm-probe)|op=mprotect\((RW|RX)->RWX\)|op=mmap\(RWX\)' "$OUT/host-vm-probe.log"
if [ "$rc" = 0 ]; then echo "PASS p0 ($OUT)"; else echo "FAIL p0 ($OUT)"; fi
exit "$rc"
