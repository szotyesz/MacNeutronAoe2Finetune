# MacNeutron AoE2DE fine-tune — plan R2

Updated: 2026-10-06. This fork of [MacNeutron](https://github.com/chadouming/MacNeutron) (base `8813ac1f982f`) tunes it for Age of Empires II: Definitive Edition. The plan comes from [Aoe2MacSteamNoRosetta](https://github.com/szotyesz/Aoe2MacSteamNoRosetta), whose earlier own-Wine plan (R1) is archived there at `docs/archive/plan-r1-own-wine.md`; its tests, evidence and route review stay in that repository and are referred to below as "the companion repository".

## 1. Goal and decision

**Goal.** Run the Windows build of Age of Empires II: Definitive Edition on an M4 Mac, with Metal GPU rendering, practical single-player performance and completed multiplayer matches against Windows players. Everything that runs on macOS is arm64; no Rosetta process is ever involved. The longer-term goal is a general Wine that also runs 32-bit x86 programs robustly.

**Decision (R2).** Stop developing this project's own Wine 11.4 runtime. Build on [MacNeutron](https://github.com/chadouming/MacNeutron) (this fork), which already implements the architecture this project was converging on:

| Layer | MacNeutron (snapshot `8813ac1f982f`, 2026-10-05) |
|---|---|
| Wine | Upstream wine-11.19 (`455e3509b98a`) + 20 patches: entitled soft PAGEZERO, 4 KiB exec, x18 toggled at every PE↔unix boundary, W^X fault flip, CPU ID registers, EC_CODE views, winemac `macdrv_functions`, msync, lsteamclient build |
| x86-64 | Upstream FEX `4ed80fd071` + 5 patches, including a macOS unixlib and JIT output through a writable view mapped beside an executable view (no RWX) |
| GPU | DXMT fork `1fba8d25b5e2` built as ARM64X PE + aarch64 `winemetal.so`, D3D11 and D3D12 |
| Steam | Native arm64 **Mac Steam** client. Windows games reach it through Proton's `lsteamclient`, built for arm64 against Mac Steam's `steamclient.dylib`. Mac Steam is switched into "Linux mode" (`steam_dev.cfg`: `@sSteamCmdForcePlatformType linux`) so compatibility-tool mappings work and it downloads Windows depots |
| Not yet | 32-bit (its roadmap row 8), Direct3D 9 (row 7), media playback — `winedmo` is a stub and `winegstreamer` is not built (row 10) |

Claims about MacNeutron in this plan come from its README, design specs and acceptance documents. They are self-reported results on the maintainer's M5 Pro and must be reproduced here (N0–N2) before relying on them.

**Why not continue the own runtime.** It would re-implement the same 20 Wine patches, FEX port, DXMT port and Steam bridge. The work done so far (P0 host tests, M0's 32 console tests, the EM-1/EM-2 executable-memory findings, the x18 signal-race review) carries over as an audit and test suite for MacNeutron instead.

**Requirements this decision brings.**
- **macOS 27.** MacNeutron targets and tests only macOS 27 (the APIs exist from 26.6; 27 is its maintainer's choice). This Mac gets macOS 27; the 26.6.2 SIP-disabled install stays available for comparison.
- **Signing.** MacNeutron builds only with a Developer ID that Apple has granted `com.apple.developer.cross-architecture-support` ("Cross-architecture Compatibility Framework") for its own App ID, plus a provisioning profile. It has no ad-hoc mode. Its released app, if one exists, is signed by the maintainer's team and may run unmodified. Building it here needs either an Apple grant for this project's own App ID, or an ad-hoc mode for a SIP/AMFI-disabled machine (N1).
- **Patch management.** Default: a private fork (`aoe2` branch) with AoE2DE-specific changes, and generic fixes offered upstream as small reviewed patches. MacNeutron's own code is MIT; its Wine and DXMT patches are LGPL-2.1+; FEX patches MIT; lsteamclient is under Valve's Steamworks SDK licence (personal use; do not redistribute builds containing it without checking the licence).

## 2. Rules carried over from R1

1. Every stage ends with evidence: commands, exact source revisions, binary hashes, logs, pass/fail per named test ID. Stage results go in `aoe2/results/<stage>.md` in this fork; large logs stay under `$AOE2_WORK_ROOT`.
2. Distinguish *read in source*, *built*, *runtime passed*, and *reported by MacNeutron*.
3. No Rosetta, ever, including build tools. Every stage records `verify-no-rosetta` evidence: architecture of every executed Mach-O and of every running process during the test.
4. A failing test is reduced to a reproducer before changing the runtime. No stubbed successes, weakened assertions or disabled tests.
5. Patches are real `git format-patch` output against a declared base, one concern per patch, with the failure that required it in the message (MacNeutron's own convention).
6. Steam credentials, SteamIDs and auth tickets never go into logs or the repository (MacNeutron's probe has `PROBE_REDACT=1`; keep it on).
7. Never modify the user's real Steam library or saves to reset a test. Use a separate Steam library folder for experiments.

## 3. Stages

### N0 — try MacNeutron as released (hours)

On macOS 27, SIP enabled, ordinary security settings:

1. Check whether a signed MacNeutron release exists on its GitHub releases page; record version and SHA-256. If none exists, skip to N1.
2. Install it as its README describes. Record what it changes in Steam's files (`steam_dev.cfg`, `config.vdf` `CompatToolMapping`, `compatibilitytools.d`). Back these up before running it.
3. In Mac Steam, set AoE2DE (app 813780) to run through MacNeutron. A native macOS AoE2DE build reportedly exists without crossplay with Windows [unverified]; confirm Steam downloads the **Windows** depot (check `steamapps/appmanifest_813780.acf` and the presence of `AoE2DE_s.exe`).
4. Launch: menu, a 10-minute skirmish, exit. Then a private multiplayer lobby with a Windows player.
5. Record per item: works / broken / how broken, plus `MACNEUTRON_LOG=1` logs and `ps`/`file` evidence of no Rosetta.

**Exit:** a written N0 report. It decides the size of N3: if menu, skirmish and a Windows-peer match work, N3 is tuning; if not, the first failure becomes N3's first reproducer.

### N1 — build it here

1. This fork exists; its base is MacNeutron `8813ac1f982f`. Keep `main` as a mirror of upstream and do AoE2DE work on an `aoe2` branch.
2. Signing, in order of preference:
   - **a)** Apply to Apple for the cross-architecture capability for this project's own App ID and build exactly as MacNeutron documents (record the request and Apple's answer in `aoe2/entitlement.md`).
   - **b)** Until then, add an opt-in **ad-hoc mode** for a SIP/AMFI-disabled macOS 27 install: ad-hoc signature with the entitlements this machine accepts (P0 showed `com.apple.developer.cross-architecture-support-unmanaged` works ad-hoc on 26.6.2 with SIP off; test which name 27 accepts), no provisioning profile. Patch 0007 ("refuse to exec a loader without the cross-arch entitlement") must check whichever entitlement is used. Keep this mode clearly marked as unsuitable for normal machines.
3. Run `make wine-arm64` and `make wine-arm64-check`. Their check needs things this project must supply or skip explicitly:
   - **SMITE 2** (used by `steam-bridge` and the FSR 3 check). Replace with an AoE2DE-based bridge probe (`steam_api64.dll` from the AoE2DE install) in the fork, or install SMITE 2 (free to play).
   - The **frozen Rosetta reference** (G4 baseline, D3DMetal comparison lanes). Running it uses Rosetta, which this project forbids. Skip those lanes and record the skip; never install Rosetta to satisfy them.
   - Screen Recording permission for `winshot`.
4. Keep MacNeutron's own pin files (`wine-arm64/pins`, `wine-arm64/deps.pins`, `dxmt/pins`) as the source of truth; record any pin change with its reason.

**Exit:** the fork builds from a clean checkout and every non-Rosetta gate of `make wine-arm64-check` passes on this M4, with logs.

### N2 — audit with this project's tests

Port the companion repository's tests to run against this fork's `wine.app` (add them under `aoe2/tests/`, keeping their licence headers):

| Test set | Source in the companion repository | Purpose |
|---|---|---|
| P0 host probes | `scripts/test-platform.sh`, `scripts/test-host-vm.sh` | Re-run on macOS 27; confirm 4 KiB, x18, TSO and W^X behaviour on this M4 |
| M0 console suite (32 checks) | `scripts/test-m0.py`, `tests/m0/`, `tests/hello-a64/` | ARM64 programs on MacNeutron's Wine; add an x86-64 build of the same programs under FEX |
| Executable memory (41 checks) | `tests/m0/runtime.c` exec cases, `tests/exec-memory/` | Its W^X flip should make A64-EXEC-HEAP and A64-EXEC-RWX pass; confirm, and confirm host mappings never have W and X together |
| x18 signal stress (new) | R1 review finding R1-X18-RACE | High-rate timer signals while guest threads make syscalls and unix calls, 60 s. MacNeutron's `check.sh x18` covers a suspend stress; this adds signal timing at every boundary |
| Rosetta check (new) | — | `scripts/verify-no-rosetta.sh`: every Mach-O executed and every live process during a test is arm64 |

Review items from R1 to check against MacNeutron's code (they may or may not apply): 4 KiB exec path and signal forwarding; TSO enabled only where translated code runs, and FEX told that hardware TSO is on; per-transition overhead with diagnostics off; Wine winetest modules (ntdll, kernel32, kernelbase) in ARM64 and x86-64-under-FEX lanes.

**Exit:** each finding is confirmed with a reproducer and fixed in the fork (and offered upstream), or ruled out with evidence.

### N3 — AoE2DE

Fixed test configuration first: Mac model, macOS build, display, game build and depot ID, game settings, fork commit.

| ID | Test | Oracle |
|---|---|---|
| G-INSTALL | Windows depot installed through Mac Steam | Windows executables present; app manifest shows the Windows depot |
| G-STEAMAPI | AoE2DE initialises the Steam API through the bridge | Game reaches its main menu signed in; no Steam error dialog |
| G-MENU | Three cold launches to the menu | Each reaches menu; animated rendering, text, mouse, keyboard, audio; normal exit |
| G-TEXT | Menu and in-game text | Correct glyphs (DirectWrite/D2D path); compare against a Windows screenshot |
| G-MEDIA | Intro/campaign videos | Plays, or is a recorded gap. MacNeutron has no media backend yet (roadmap row 10); a media backend for `winedmo` is likely needed for AoE2DE's videos |
| G-PLAY | 30-minute skirmish | Camera, selection, commands, hotkeys, UI, pathfinding; no crash |
| G-SAVE | Save, quit, reload | Same game state |
| G-WINDOW | Windowed/borderless/fullscreen, resize, focus switch, 20 cycles | Rendering and input recover; MetalFX upscaling behaves |
| G-PERF | Fixed replay or scenario, 3 runs | Median, p95 and p99 frame time; CPU and GPU utilisation; compared with an agreed target |
| G-LATE | Large late-game scenario | Stable memory after warm-up; no stutter beyond the agreed limit |

**Exit:** all G tests pass or have a named, accepted gap.

### N4 — multiplayer with Windows players

AoE2DE multiplayer is lockstep simulation; any floating-point or ordering difference desyncs. Proton on Linux uses the same bridge design and has worked for AoE2DE multiplayer, which is a good precedent for the Steam side; FEX on macOS is the new part.

1. Confirm FEX settings that affect determinism: full x87 precision (`X87ReducedPrecision=0`), TSO behaviour, and any FEX option that trades accuracy for speed. Record the settings used.
2. Matching game version with the Windows peer; unmodded baseline.
3. Three completed matches including one of at least 30 minutes; host once from the Mac and once from Windows; chat/invites; logout and second login.
4. On any desync, keep game version, fork commit and FEX settings fixed, save the replay and reduce to a floating-point/atomic reproducer before changing anything.

**Exit:** three completed Windows-peer sessions, no desync, no Rosetta processes.

### N5 — robustness and the wider goal

| ID | Item | Notes |
|---|---|---|
| N5.1 | **32-bit (WoW64)** | MacNeutron roadmap row 8: i386 in `--enable-archs`, FEX `libwow64fex.dll`, dual-view JIT for WoW64 (FEX's WoW64 JIT still allocates RWX). Reuse R1's M1.6 test table (companion repository, archived plan, section 10.1): i386 hello/memory/thread/SEH/IO, large-address-aware layout, suspend, mixed 32/64-bit child processes, winetest i386 lane. Coordinate with MacNeutron before starting, to avoid duplicate work |
| N5.2 | **Direct3D 9** | Roadmap row 7 (dacevedo12/dxmt `v0.4-d3d9`); wined3d as fallback |
| N5.3 | **Media** | Roadmap row 10, if not already forced by G-MEDIA |
| N5.4 | **Regression lanes** | Rebuild and re-run N1's gates, N2's suites and a short N3 smoke test on every MacNeutron, Wine, FEX or DXMT pin change and every macOS update |
| N5.5 | **Steam-mode fragility** | The Linux-mode switch is undocumented. Document the manual fallback: download the Windows depot from the Steam console (`download_depot 813780 <depot>`) and launch through the bridge without compatibility-tool mapping |
| N5.6 | **Windows Steam inside Wine** (optional) | A stress test of the general Wine, not needed for AoE2DE: Chromium-based `steamwebhelper` under FEX, mixed 32/64-bit installers. Steam notes from Madeira apply. Starts only after N5.1 |
| N5.7 | **Security setting** | Re-run N1–N4 smoke tests on a normal SIP-enabled macOS 27 install once a properly entitled build exists |

## 4. Relationship to the companion repository

[Aoe2MacSteamNoRosetta](https://github.com/szotyesz/Aoe2MacSteamNoRosetta) keeps:
- the P0 host probes, M0 console suite and executable-memory probes (to be ported here in N2);
- evidence measured on macOS 26.6.2 (`docs/m0-results.md`, `docs/executable-memory.md`, `docs/evidence/`);
- the route review (`docs/route-review.md`) explaining why this architecture was chosen;
- the archived own-Wine plan R1 and its frozen Wine 11.4 patches.

No further runtime development happens there. New work, results and patches go in this fork.

## 5. Immediate next steps

1. Install macOS 27 on the M4 (separate volume recommended, keeping the 26.6.2 install).
2. N0: try a released MacNeutron with AoE2DE; write `aoe2/results/n0.md`.
3. In parallel, request the cross-architecture capability from Apple for this project's own App ID.
4. N1: fork, ad-hoc mode if needed, reproduce `make wine-arm64-check`.

## 6. References

- MacNeutron: [`README.md`](../README.md), [`wine-arm64/README.md`](../wine-arm64/README.md), design specs under [`docs/superpowers/specs/`](../docs/superpowers/specs/), acceptance results under [`docs/testing/`](../docs/testing/).
- [Route review, 2026-10-06](https://github.com/szotyesz/Aoe2MacSteamNoRosetta/blob/main/docs/route-review.md) and [plan R1](https://github.com/szotyesz/Aoe2MacSteamNoRosetta/blob/main/docs/archive/plan-r1-own-wine.md) in the companion repository.
- Proton `lsteamclient`: https://github.com/ValveSoftware/Proton, `lsteamclient/` at `db9e6ffbf24a` (MacNeutron's pin).
- Apple macOS 27 release notes on Rosetta's end of general support after macOS 27.
