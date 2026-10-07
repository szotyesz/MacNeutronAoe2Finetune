# Cross-architecture entitlement (plan R2, N1 step 2)

Updated: 2026-10-07.

## a) Apple grant for this project's own App ID

Not requested yet. When requested, record here: date, App ID, team, the capability asked for
(`com.apple.developer.cross-architecture-support`, "Cross-architecture Compatibility Framework"), and Apple's answer.
The companion repository's `docs/entitlement-audit.md` records an earlier attempt on another install that did not work.
Its exact errors were not captured.

## b) Ad-hoc mode on this Mac

Host: Mac16,13 (Apple M4), macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), SDK 27.0. `csrutil status`: disabled. Boot
arguments: `amfi_get_out_of_my_way=0x1`. Rosetta: not installed (`/Library/Apple/usr/libexec/oah` holds only
`RosettaLinux`).

Probe: the companion repository's `tests/platform/capabilities.c` + `x18.S` (at `f37dfc2`), built with
`-Wl,-x86_64_layout_emulation -Wl,-pagezero_size,0x100000000`. It was ad-hoc signed once per entitlement set and run
2026-10-07. Each child is spawned with `posix_spawnattr_set_4k_page_size_np`.

| Entitlements in the ad-hoc signature | memory (4K pages, map at 0x7ffe0000, 4K protection) | x18 | TSO |
|---|---|---|---|
| `com.apple.developer.cross-architecture-support` | PASS | PASS | PASS |
| `com.apple.developer.cross-architecture-support-unmanaged` | PASS | PASS | PASS |
| both | PASS | PASS | PASS |
| none | FAIL: `4 KiB spawn: Malformed Mach-o file` | FAIL (same) | FAIL (same) |

On macOS 27.0.1 with SIP and AMFI off, the **managed** name works ad hoc. This is the name Wine patch 0007 checks.
That patch needs no change. The fork's ad-hoc mode (`MACNEUTRON_ADHOC=1`, `wine-arm64/lib.sh`) signs the loader with
`wine-arm64/wine-adhoc.entitlements`: the managed name plus the three `com.apple.security.cs.*` keys of
`wine.entitlements`, without `com.apple.application-identifier` and `com.apple.developer.team-identifier`, which name
the maintainer's team.

This shows only that the kernel honours the entitlement on this configuration. It does not show that Apple has
authorised this project, and it does not show anything about a Mac with SIP or AMFI enforcing (N5.7).
