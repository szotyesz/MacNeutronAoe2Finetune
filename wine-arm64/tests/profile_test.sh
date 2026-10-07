#!/bin/sh
# lib.sh's check_profile_plist against decoded-profile fixtures (native arm64 plan, Task 2). No keychain, no network.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
F="$ROOT/wine-arm64/tests/fixtures"
. "$ROOT/wine-arm64/lib.sh"

# expect <fixture> <exit status> [<text the message contains>]
expect() {
  out=$( (check_profile_plist "$F/$1.plist") 2>&1 ) && st=0 || st=$?
  [ "$st" = "$2" ] || { echo "FAIL profile_test: $1 exited $st, wanted $2: $out"; exit 1; }
  case "$out" in *"${3:-}"*) ;; *) echo "FAIL profile_test: $1 said [$out], wanted [$3]"; exit 1 ;; esac
}
expect good 0
expect wrong-app 1 "profile is for 49QMZXLR8S.com.example.other, not 49QMZXLR8S.net.authspot.macneutron.wine"
expect no-entitlement 1 "profile lacks com.apple.developer.cross-architecture-support"
expect expired 1 "profile expired on"
# PlistBuddy prints English dates whatever the locale; date must read them as English too (this Mac lists fr-CA).
( LC_ALL=fr_FR.UTF-8; export LC_ALL; expect good 0 )

# check_signing names what is missing or wrong, before anything is built. (A good profile needs a signed one: bundle.sh.)
sign() {  # sign <identity> <profile> <message>: "-" leaves the variable unset
  out=$( (unset MACNEUTRON_SIGN_IDENTITY MACNEUTRON_PROVISIONING_PROFILE MACNEUTRON_ADHOC
          [ "$1" = - ] || MACNEUTRON_SIGN_IDENTITY=$1
          [ "$2" = - ] || MACNEUTRON_PROVISIONING_PROFILE=$2
          check_signing) 2>&1 ) && st=0 || st=$?
  [ "$st" = 1 ] && [ "$out" = "wine-arm64: $3" ] || { echo "FAIL profile_test: check_signing $1 $2 said [$out] ($st), wanted [$3]"; exit 1; }
}
sign - /etc/hosts "set MACNEUTRON_SIGN_IDENTITY"
sign id - "set MACNEUTRON_PROVISIONING_PROFILE"
sign id /etc/hosts "/etc/hosts is not a provisioning profile"
sign id /no/such/profile "/no/such/profile is not a provisioning profile"

# MACNEUTRON_ADHOC=1 (this fork's ad-hoc mode): no identity or profile beside it, and a Mac with SIP disabled and AMFI
# out of the way, read through stand-ins for csrutil and sysctl. On such a Mac the identity becomes -.
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
adhoc_case() {  # adhoc_case <identity> <profile> <csrutil status> <boot-args> <want>: "-" leaves the variable unset
  printf '#!/bin/sh\necho "System Integrity Protection status: %s."\n' "$3" > "$T/csrutil"
  printf '#!/bin/sh\necho "%s"\n' "$4" > "$T/sysctl"
  chmod +x "$T/csrutil" "$T/sysctl"
  out=$( (unset MACNEUTRON_SIGN_IDENTITY MACNEUTRON_PROVISIONING_PROFILE; MACNEUTRON_ADHOC=1 PATH="$T:$PATH"
          [ "$1" = - ] || MACNEUTRON_SIGN_IDENTITY=$1
          [ "$2" = - ] || MACNEUTRON_PROVISIONING_PROFILE=$2
          check_signing && echo "identity $MACNEUTRON_SIGN_IDENTITY") 2>&1 ) || true
  [ "$out" = "$5" ] || { echo "FAIL profile_test: ad hoc $1 $2 [$3] [$4] said [$out], wanted [$5]"; exit 1; }
}
off=amfi_get_out_of_my_way=0x1
adhoc_case - - disabled "$off" "identity -"
adhoc_case - - disabled "-v amfi_get_out_of_my_way=1 debug=0x100" "identity -"
adhoc_case - - enabled "$off" "wine-arm64: MACNEUTRON_ADHOC=1 needs System Integrity Protection disabled (csrutil status)"
adhoc_case - - disabled "" "wine-arm64: MACNEUTRON_ADHOC=1 needs the boot-arg amfi_get_out_of_my_way=1"
adhoc_case - - disabled "amfi_get_out_of_my_way=0" "wine-arm64: MACNEUTRON_ADHOC=1 needs the boot-arg amfi_get_out_of_my_way=1"
adhoc_case id - disabled "$off" "wine-arm64: MACNEUTRON_ADHOC=1 signs ad hoc: unset MACNEUTRON_SIGN_IDENTITY"
adhoc_case - /etc/hosts disabled "$off" "wine-arm64: MACNEUTRON_ADHOC=1 embeds no profile: unset MACNEUTRON_PROVISIONING_PROFILE"
echo PASS profile_test
