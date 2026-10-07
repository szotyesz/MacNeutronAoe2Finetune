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

# Ad-hoc mode (aoe2 fork): only on a host with SIP and AMFI off, and without the Developer ID variables. The host is
# faked: sign_adhoc <sip line> <boot args> <identity> <profile> <status> <message or the identity it leaves>.
sign_adhoc() {
  out=$( (unset MACNEUTRON_SIGN_IDENTITY MACNEUTRON_PROVISIONING_PROFILE; MACNEUTRON_ADHOC=1
          sip=$1 args=$2
          sip_status() { echo "System Integrity Protection status: $sip."; }; boot_args() { echo "$args"; }
          [ "$3" = - ] || MACNEUTRON_SIGN_IDENTITY=$3
          [ "$4" = - ] || MACNEUTRON_PROVISIONING_PROFILE=$4
          check_signing; echo "identity=$MACNEUTRON_SIGN_IDENTITY $(basename "$(entitlements_file)")") 2>&1 ) && st=0 || st=$?
  [ "$st" = "$5" ] && { [ "$out" = "wine-arm64: $6" ] || [ "$out" = "$6" ]; } \
    || { echo "FAIL profile_test: sign_adhoc $*: said [$out] ($st)"; exit 1; }
}
sign_adhoc disabled amfi_get_out_of_my_way=0x1 - - 0 "identity=- wine-adhoc.entitlements"
sign_adhoc disabled "-v amfi_get_out_of_my_way=1" - - 0 "identity=- wine-adhoc.entitlements"
sign_adhoc enabled amfi_get_out_of_my_way=0x1 - - 1 \
  "MACNEUTRON_ADHOC=1 needs System Integrity Protection disabled (csrutil status)"
sign_adhoc disabled "" - - 1 "MACNEUTRON_ADHOC=1 needs the boot argument amfi_get_out_of_my_way=0x1"
sign_adhoc disabled amfi_get_out_of_my_way=0 - - 1 "MACNEUTRON_ADHOC=1 needs the boot argument amfi_get_out_of_my_way=0x1"
sign_adhoc disabled amfi_get_out_of_my_way=0x1 id - 1 "MACNEUTRON_ADHOC=1 signs ad hoc: unset MACNEUTRON_SIGN_IDENTITY"
sign_adhoc disabled amfi_get_out_of_my_way=0x1 - /etc/hosts 1 \
  "MACNEUTRON_ADHOC=1 embeds no profile: unset MACNEUTRON_PROVISIONING_PROFILE"
# Without MACNEUTRON_ADHOC=1 the Developer ID entitlements are the ones used.
[ "$(unset MACNEUTRON_ADHOC; basename "$(entitlements_file)")" = wine.entitlements ] \
  || { echo "FAIL profile_test: entitlements_file without MACNEUTRON_ADHOC"; exit 1; }
echo PASS profile_test
