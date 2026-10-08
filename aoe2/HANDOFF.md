# Hand-off: state on 2026-10-07 and how to rebuild it

This file is the restart point. It lists where plan R2 (`aoe2/PLAN.md`) stands, how to rebuild exactly this state on a
fresh macOS install with the work on an external SSD, and what to do next. The detailed results are in
`aoe2/results/n1.md`, `n2.md` and `n3.md`.

## 1. Where things stand

| Stage | Status |
|---|---|
| N0 | Skipped (no signed MacNeutron release used) |
| N1 — build it here | **Passed.** Ad-hoc signing mode (`MACNEUTRON_ADHOC=1`). A clean-checkout rebuild passes every `check.sh` step this project may run, `steam-bridge` (with AoE2DE's `steam_api64.dll`) and `dxmt-present` included |
| N2 — audit | **In progress.** Every ported suite passes in the native and FEX lanes (P0, M0 41/41 ×2, W^X scan, x18 signal stress). Wine patches 0021 (write-watched RWX spin) and 0022 (signal on dyld's stack) fix the two bugs found. Open: 10 winetest units that fail only, or differently, under FEX (`n2.md`, "Open") |
| N3 — AoE2DE | **In progress.** G-INSTALL passes; with no mods the menu shows at +19 s. Wine 0023–0027, DXMT 0003 and FEX 0006–0010 fix start-up, the reporter deadlocks (N3-F4, N3-F5), the mods stall (N3-F6: Arxan's self-modifying code under FEX; 27 mods load in ~24 s) and the black window with mods (N3-F7: a FEX self-deadlock from patch 0009, fixed by 0010). G-TEXT's cause is fixed (DXMT 0003), not yet confirmed in game. Open: with any mod, a long Arxan phase after setup keeps the menu from showing until the hang reporter ends the game (~3.5 min); a rare start-up crash in Steam init (`results/n3.md`) |
| N4, N5 | Not started |

Commits on `aoe2` since the plan: `5959601` (N1 ad-hoc mode), `d799f74` (N2 tests, patches 0021–0022), `21a013f` (N1
passed), `ec23d32` (patch 0023), `abec3b8` (check.sh `printf`), and this hand-off. The installed runtime on the old
machine was built from `ec23d32` (Wine series `f0ecdcbd…`, 23 patches).

## 2. Rebuild on a fresh install, with the work on an external SSD

Everything below was done on a Mac16,13 (M4) running macOS 27.0.1 (26A434), Xcode 27.0 (27A266a). Times are from there.

### 2.1 Host settings (once)

1. **SIP off and AMFI relaxed.** The ad-hoc runtime runs only on such a host (`aoe2/entitlement.md`). Boot into
   recoveryOS, open Terminal, run `csrutil disable`, and restart. Then run
   `sudo nvram boot-args="amfi_get_out_of_my_way=0x1"` and restart again. Check with `csrutil status` (should say
   "disabled") and `sysctl -n kern.bootargs`.
2. **No Rosetta, ever** (plan rule 3). Decline every offer to install it. `/Library/Apple/usr/libexec/oah` must hold
   only `RosettaLinux`.
3. **Xcode 27** in `/Applications`, opened once. Then either `sudo xcode-select -s /Applications/Xcode.app` or
   `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` in every shell, then
   `xcodebuild -downloadComponent MetalToolchain` (about 840 MB).
4. **Homebrew**, then `brew install autoconf bison flex cmake ninja meson pkg-config gettext`. The build uses the
   keg-only `bison` and `flex` by itself.
5. **Privacy & Security** for the terminal app: **Screen Recording** (`check.sh dxmt-present`, `winshot`). Grant it,
   then quit and reopen the terminal. Accessibility is not needed.
6. **External SSD** formatted **APFS**. The build relies on `cp -c` clones; the default case-insensitive variant is
   fine. Leave about 60 GB free: the AoE2DE Windows build is 24 GB, a full build tree 14 GB, a second clean clone
   another 14 GB when checking a rebuild, plus prefixes and logs. Below, `SSD=/Volumes/<name>`.
7. Shell setup, in `~/.zshrc`:
   ```sh
   export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # unless xcode-select points there
   export AOE2_WORK_ROOT=$SSD/aoe2-poc-work                          # evidence, logs, scratch; never in git
   ```

### 2.2 Checkouts

```sh
cd "$SSD"
git clone --branch aoe2 git@github.com:szotyesz/MacNeutronAoe2Finetune.git
git clone git@github.com:szotyesz/Aoe2MacSteamNoRosetta.git   # companion; optional, aoe2/tests carries what N2 used
cd MacNeutronAoe2Finetune
```

`aoe2/tests/m0/runtime.c` holds the companion's R1 review cases (`cpuid`, `x18-stress`, `wait`). They were never
committed in the companion repository, so nothing is lost if its working tree is discarded.

### 2.3 Pinned tarballs (this network cannot reach GNU's servers)

`ftp.gnu.org` and `download.savannah.gnu.org` timed out from here. `make wine-arm64` reuses a tarball that is already
in place, and still checks its SHA-256. Fetch them first:

```sh
. wine-arm64/deps.pins; D=build/wine-arm64-src; mkdir -p $D
get() { curl -fL -o "$D/$(basename "$1")" "$2" && [ "$(shasum -a 256 "$D/$(basename "$1")" | cut -d' ' -f1)" = "$3" ] \
  && echo "ok $(basename "$1")" || { rm -f "$D/$(basename "$1")"; echo "BAD $(basename "$1")"; }; }
get "$GMP_URL"      "${GMP_URL/ftp.gnu.org/mirrors.kernel.org}"      "$GMP_SHA256"
get "$NETTLE_URL"   "${NETTLE_URL/ftp.gnu.org/mirrors.kernel.org}"   "$NETTLE_SHA256"
get "$FREETYPE_URL" "https://sourceforge.net/projects/freetype/files/freetype2/2.14.3/freetype-2.14.3.tar.xz/download" "$FREETYPE_SHA256"
get "$GNUTLS_URL"   "$GNUTLS_URL"                                    "$GNUTLS_SHA256"   # gnupg.org worked
```

### 2.4 Build (about 22 min cold) and the gates (about 20 min)

```sh
MACNEUTRON_ADHOC=1 make wine-arm64          # build/wine-arm64/wine.app; ends with "staged ... (dev)"
make build bridge wine-arm64-tests dxmt-tests dxmt-tests-arm64ec presenter
sh wine-arm64/tests/mode_test.sh && sh wine-arm64/tests/profile_test.sh
sh wine-arm64/tests/licences_test.sh build/wine-arm64/wine.app && sh wine-arm64/tests/licences_test.sh --self-test build/wine-arm64/wine.app
# every step except the three that need the Rosetta reference (dxmt-arm64ec, dxmt-x64, g4-bench):
export MACNEUTRON_STEAM_API="<Steam library>/steamapps/common/AoE2DE/steam_api64.dll"   # after 2.5; steam-bridge needs it
sh aoe2/tests/verify-no-rosetta.sh "$AOE2_WORK_ROOT/rosetta-check" sh wine-arm64/check.sh macos signature boot pages \
  unentitled arm64 isec g3-cpu fex g1-hello g1-seh g1-threads g1-kuser g1-smc g1-tsc g1-unaligned g2-litmus viewec \
  wxflip wxwatch wxflip-x64 msync x18 apcsuspend globalroot g5-jit fonts-tls steam-bridge dxmt dxmt-present
```

Expect PASS on every step, then `PASS orphans` and `PASS verify-no-rosetta`. `steam-bridge` needs Mac Steam running and
signed in. Its very first run after Steam restarts can miss the auth-ticket callback once (`n1.md`); rerun it.
`dxmt-present` needs nothing in native full screen on the main display. The N2 suites are run as `aoe2/tests/README.md`
describes (`p0.sh`, `m0.py --exec-memory`, `wx-scan.sh`, `x18-signal/run.sh`, `winetest.py`). The Wine test build
for `winetest.py` is a second configure, given there.

`sh wine-arm64/check.sh <steps>` runs single steps. Its scratch folder `build/wine-arm64 check/` (2.5 GB or more) can
be deleted at any time.

### 2.5 MacNeutron, Steam and AoE2DE

1. `MACNEUTRON_ADHOC=1 make app`, then `cp -cR build/MacNeutron.app /Applications/`. A rebuilt app replaces an
   installed one only while Steam and MacNeutron are quit; quit MacNeutron from its menu-bar item.
2. Install Mac Steam (`/Applications/Steam.app`) and sign in. To keep the game on the SSD, add a library folder there
   (Steam › Settings › Storage) and make it the default **before** installing AoE2DE. The game's Wine prefix then lives
   in `<library>/steamapps/compatdata/813780/pfx`.
3. Open `/Applications/MacNeutron.app`. Its setup installs the runtime and turns on **Steam Play mode**: Steam is
   restarted with `steam_dev.cfg` inside Steam's bundle, `Steam.AppBundle/Steam/Contents/MacOS/steam_dev.cfg`. It
   backs up Steam's `config.vdf` first.
4. In MacNeutron's **Games** window, set *Age of Empires II: Definitive Edition* to **Windows version** and turn its
   **log** on. That writes `~/Library/Application Support/MacNeutron/games/813780.json` =
   `{"log":true,"runAs":"windows"}`. Restart Steam if MacNeutron asks.
5. Install AoE2DE in Steam. Check it is the Windows build: `appmanifest_813780.acf` lists depots 813781…4376980, not
   1022227…; `AoE2DE_s.exe` is PE32+ x86-64; there is no `.app`. N3 used build `25464371`. A newer build may behave
   differently, so record the build ID.
6. While Steam Play mode is on, a Mac game must stay mapped to MacNeutron's native tool, or Steam deletes its files at
   the next start. MacNeutron keeps that mapping; don't edit `CompatToolMapping` by hand.

### 2.6 Reproduce N3's current state

```sh
open "steam://rungameid/813780"   # or launch from Steam
```

Seen with the `ec23d32` runtime:
- The splash screen, then a D3D11 device at feature level 11_0.
- About 80 s after launch, exit 2. The log `~/Library/Logs/MacNeutron/steam-813780.log` ends with
  `err:virtual:virtual_setup_exception nested exception on signal stack addr 0x19cc4c10c` (N3-F2).
- A replay launched outside Steam (below) stayed up for minutes at the menu. The user saw clicks ignored and garbled
  graphics there.

The replay tools are in `aoe2/tools/`:

```sh
python3 aoe2/tools/replay-launch.py --save-env       # once, after one Steam launch with the game's log on
python3 aoe2/tools/replay-launch.py "$AOE2_WORK_ROOT/n3/run1" 150 GAME_ARGS=SKIPINTRO
build/wine-arm64-tests/winshot "Age of Empires II: Definitive Edition" shot.png   # the game window, without raising it
```

**Warning:** `WINEDEBUG=+seh` on the game writes about 1 GB a minute: N3-F3's exceptions each log several lines. It
filled the disk once. Use it only for short runs, or filter (`warn+seh`, or a narrower channel), and watch `df`.

## 3. Next steps, in order

1. **Exception cost (N3-F3).** `wine-arm64/tests/x64-trapcost.c` is written but has **not been built or run yet**. It
   is built as x64 (`make build/wine-arm64-tests/x64-trapcost.exe`, run under FEX) and, from the same source, as
   ARM64:
   `$(sh dxmt/toolchain.sh)/aarch64-w64-mingw32-clang -O1 -fms-extensions -D_WIN32_WINNT=0x0A00 -o build/wine-arm64-tests/arm64-trapcost.exe wine-arm64/tests/x64-trapcost.c`.
   Run both in a prefix with FEX registered (`HKLM\Software\Microsoft\Wow64\amd64` (Default) = `libarm64ecfex.dll`).
   Each prints the µs per illegal-instruction exception handled by a vectored handler, per `RaiseException`, and per
   plain call. Compare with Windows: a few µs per exception.
   - **Budget:** 720,000 exceptions in 80 s would cost about 9 µs each if they took all the time. If the measured
     cost is near or above that, the storm alone explains the frozen menu.
2. **The crash (N3-F2) without heavy tracing.**
   - Launch from Steam with the default log (`+err,+warn,+loaddll,+steamclient`).
   - Check `~/Library/Logs/DiagnosticReports/` for a `wine-*.ips` crash report.
   - Look at what the main thread did last; `lldb` can attach (SIP off), but cannot read below 4 GB
     (`n3.md` explains why).
   - Suspects: the signal path under the exception storm. Is the signal stack exhausted by nested signals? Is the
     x18 state right on that path, where patch 0022 changed classification?
3. **Where the time goes in an exception.**
   - Profile the trap loop natively and under FEX (`sample <pid>`, or Instruments' Time Profiler), from host signal →
     `virtual_handle_fault`/`segv_handler` → Wine's user-mode dispatch (`KiUserExceptionDispatcher`,
     `RtlDispatchException`, the vectored handler) → back to FEX's JIT.
   - Likely costs: context conversion (ARM64EC↔x64), the x18 toggles, `NtContinue`, FEX block re-entry or cache
     lookups.
   - Making each exception cheaper is the likely fix for the frozen menu.
4. Then G-MENU by hand: mouse, keyboard, audio, three cold launches, a normal exit; then G-TEXT, G-MEDIA and the rest
   of N3's table.
5. Still open from N2: the 10 FEX-only winetest units, hangs first (`ntdll:exception`, `kernel32:debugger`,
   `kernel32:process`).
6. Noted for later:
   - Hardware TSO is never used on macOS (FEX's unixlib refuses it): a performance candidate for G-PERF (`n2.md`, F3).
   - For N4, online play under Proton needs Microsoft's `ucrtbase.dll` from `vc_redist.x64.exe` in the prefix
     (`n3.md`).
   - The Xbox sign-in and the free "Enhanced Graphics Pack" DLC prompt.

## 4. To do: from hand testing with no mods (user, 2026-10-08)

Not investigated yet.
1. **1920x1080 in the middle of the screen.** Can the game run at 1920x1080, scaled to fit, centred, with black bars
   above and below (as the main menu looks now)?
2. **A tick every ~5 s in gameplay.** Everything freezes for a moment, audio too. Is macOS Game Mode on when it
   starts?
3. **Other renderers than DXMT?** The rendering problems are still there, and the game feels a little sluggish.
4. **Integrate CaptureAge.** On Linux this works through a wrapper exe that starts both AoE2DE and CaptureAge, so they
   run in the same environment (the same Proton prefix and session) and can share resources. Do the same here.

## 5. Not in git

These stay out of the repository on purpose. Copy them to the SSD if they are wanted.
- `$AOE2_WORK_ROOT` (on the old machine `~/aoe2-poc-work`): run logs, screenshots, process samples and `results.json`
  files for N1–N3.
  - The `n3/steam-env.txt` and `steam-backup-*` folders name the Steam account. Keep them private.
- `~/Library/Logs/MacNeutron/`: the launcher log and the game's Wine log.
- Never commit Steam credentials, SteamIDs, auth tickets, login names or `config.vdf` (plan rule 6).
