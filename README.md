# MacNeutron

Proton for macOS: Windows games from your Steam library, launched by the native macOS Steam
client and run on a native arm64 Wine with FEX (for x86-64 code) and DXMT (Direct3D to Metal).

**Status:** release 0.1.0, arm64 only. Every game runs on the native arm64 runtime (`wine.app`, inside
`MacNeutron.app`); no Rosetta is involved. 32-bit games and Direct3D 9 games are not supported in 0.1. Design:
`docs/superpowers/specs/`.

**Requirements:** an Apple Silicon Mac with macOS 27 or later, and the Steam client for Mac. Building from source also
needs Xcode 27 (Swift 6) and the Developer ID setup in `wine-arm64/README.md` (its ad-hoc mode, `MACNEUTRON_ADHOC=1`, is only for a Mac with SIP and AMFI off).

## Download and set up

1. Download `MacNeutron-<version>.zip` from the project's releases, unzip it, and move `MacNeutron.app` to
   `/Applications` before opening it (macOS runs an app opened from Downloads from a temporary read-only copy, so the
   first runtime install is a slow full copy instead of an instant clone). Upgrading from an older MacNeutron: quit
   Steam before opening the new one, and start it again after setup.
2. Open MacNeutron. The setup window checks the requirements (Steam), installs the runtime automatically, and then
   turns on Steam Play mode. After that, MacNeutron lives in the menu bar. It keeps Steam's mappings current so your
   Mac games stay native, and its Games window sets the graphics backend and options per game.

The Rosetta-era runtime downloads in `~/Library/Caches/MacNeutron/runtime-v*.tar.gz` are no longer used and can be
deleted.

## Build and test

```sh
make build   # swift build -c release
make test    # unit tests
make wine-arm64        # native arm64 Wine + FEX + DXMT in a signed wine.app (needs the Developer ID setup in wine-arm64/README.md)
make wine-arm64-check  # its gates under real Wine
make dxmt-check        # our DXMT against the frozen Rosetta reference (tools/freeze-rosetta-reference.sh)
make app               # build/MacNeutron.app with wine.app inside (needs MACNEUTRON_SIGN_IDENTITY and MACNEUTRON_PROVISIONING_PROFILE)
make release VERSION=0.1.0   # the notarized zip, the source archive and the checks (release/release.sh)
```

The runtime runs Direct3D 11/12 (D3D10's front end is bundled, untested) through our DXMT built for arm64,
ARM64EC programs natively and x64 ones under FEX (`docs/testing/acceptance-arm64-dxmt.md`). It also renders Windows
text, does TLS, synchronises with msync and reaches Steam through an arm64 Steam bridge
(`docs/testing/acceptance-arm64-ship-base.md`).
Its `wine.app` carries every component's licence in `Contents/Resources/licenses` (`wine-arm64/licenses/README`).
Portions of this software are copyright © The FreeType Project (www.freetype.org). All rights reserved.

`make wine-arm64` needs `brew install cmake ninja meson` and Xcode's Metal Toolchain
(`xcodebuild -downloadComponent MetalToolchain`). Windows-side binaries are built with Clang from the pinned llvm-mingw,
which the build fetches once (118 MB). `make app` signs with `MACNEUTRON_SIGN_IDENTITY` and
`MACNEUTRON_PROVISIONING_PROFILE`.

## Install the runtime from the command line

The app does this for you. To assemble a tool folder by hand from a built `wine.app`:

```sh
.build/release/macneutron install --tool-dir <dir> --wine-app <path to wine.app>
```

It prints `installed <label>` or `unchanged <label>` (exit 0), or `deferred: <path> is running` (exit 3) when a game is
using the current runtime. `--force` reinstalls, and `--steam-exe <path>` names the Steam bridge's `steam.exe` when the
CLI isn't beside one (a tool folder assembled from `.build/release/`).

## Per-game options

Use the app's Games window, or Steam launch options:

Start launch options with `/usr/bin/env`. macOS Steam runs them without a shell, so the Linux-style
`VAR=value %command%` fails to launch.

| Launch options | Effect |
|---|---|
| `/usr/bin/env MACNEUTRON_GRAPHICS=dxmt\|wined3d %command%` | Pick the Direct3D backend (default `dxmt`; `wined3d` is Wine's own, Direct3D 9-11 only) |
| `/usr/bin/env MACNEUTRON_LOG=1 %command%` | Wine log in `~/Library/Logs/MacNeutron/steam-<appid>.log` |
| `/usr/bin/env MACNEUTRON_NO_MSYNC=1 %command%` | Turn off msync |
| `/usr/bin/env MACNEUTRON_NO_STEAM_BRIDGE=1 %command%` | Start the game without the Steam bridge (the game then can't reach Steam) |
| `/usr/bin/env MACNEUTRON_NO_METALFX=1 %command%` | Don't upscale with MetalFX (macOS then stretches smaller images with its nearest-neighbour filter) |
| `/usr/bin/env DXMT_D3D12_SM6=1 %command%` | On DXMT, report the Direct3D 12 features Shader Model 6 games check for (Unreal Engine 5 games need it) |
| `/usr/bin/env DXMT_D3D12_OVERLAP=1 %command%` | On DXMT, let a Direct3D 12 game's GPU passes overlap between barriers (experimental: not faster on Apple GPUs so far) |
| `/usr/bin/env MACNEUTRON_PRECACHE=0 %command%` | Don't record the game's pipelines or rebuild them after updates (shader pre-caching) |

## Graphics

Games use DXMT by default, an open-source Direct3D → Metal translator. MacNeutron builds it from its own fork,
[chadouming/dxmt](https://github.com/chadouming/dxmt), with Direct3D 12 enabled. DXMT is LGPL-2.1+: the licences ship
in `wine.app/Contents/Resources/DXMT` (`COPYING.LIB`, `LICENSE`, `LICENSE.OLD`), and the fork commit is in its `version` file. The fork's
changes are AI-assisted and never go to DXMT upstream, per its contribution policy.

DXMT's Direct3D 12 is early, but it translates Shader Model 6 (DXIL) shaders: SMITE 2 (Unreal Engine 5) plays on it.
Unreal Engine 5 games check for Shader Model 6 features before they start; launch them with
`/usr/bin/env DXMT_D3D12_SM6=1 %command%`. For a game that doesn't run on DXMT yet, set
**Graphics: wined3d** for it in the Games window (or use `/usr/bin/env MACNEUTRON_GRAPHICS=wined3d %command%`); it
covers Direct3D 9-11 only.

**Shader pre-caching**, as Steam does for Vulkan games. DXMT keeps every shader it translates in a cache, so a
Direct3D 12 game translates each shader once. MacNeutron also records every pipeline the game creates, in
`dxmt-pipelines` in the game's Steam compat folder (`~/Library/Application Support/Steam/steamapps/compatdata/<appid>`).
After an update of MacNeutron's DXMT or of macOS, the launcher rebuilds them before the game starts, and a
notification says so. Troubleshooting:

- `DXMT_SHADER_CACHE=0` turns the translation cache off, and `MACNEUTRON_PRECACHE=0` turns recording and rebuilding
  off.
- Deleting `$(getconf DARWIN_USER_CACHE_DIR)dxmt/<game exe>/shaders_*.db` clears the cache.
- Deleting the `dxmt-pipelines` folder clears the recordings.

**GPU work overlap** (experimental). By default DXMT runs a Direct3D 12 game's GPU passes in strict order. With
`/usr/bin/env DXMT_D3D12_OVERLAP=1 %command%` a pass waits only on the passes the game's barriers order before it.
In SMITE 2 on Apple GPUs this added more idle time between passes than it saved
(`docs/testing/acceptance-dxmt-gpu-overlap.md`). If a game flickers or shows corrupted surfaces with it, drop it: the
cause is DXMT's ordering, so please report it. `DXMT_D3D12_MERGE=0` likewise turns off DXMT's merging of render passes that Direct3D 12 command lists
split, and of a clear into the render pass after it. `DXMT_D3D12_COMPRESSION=0` turns off DXMT's lossless compression
of Direct3D 12 textures, if a game shows corrupted textures with it. `DXMT_D3D12_INDIRECT=icb` makes DXMT write every
indirect draw into a Metal indirect command buffer again, instead of reading the simple ones straight from the game's
argument buffer, if indirect geometry (grass, particles) goes missing or flickers.

For DXMT development, `/usr/bin/env DXMT_DXIL_DUMP=/Users/<you>/dxil %command%` saves each DXIL shader a game creates
into that folder. Give an absolute path: Steam runs launch options without a shell, so `~` and `$HOME` aren't expanded.
While it's set, DXMT also reports the Shader Model 6 features, as `DXMT_D3D12_SM6=1` does.

## Steam API

Windows games talk to your running Mac Steam through the runtime's Steam client bridge (Proton's `lsteamclient`,
built for arm64 by `wine.app`, and shipped under Valve's Steamworks SDK licence, see `licenses/lsteamclient/`). MacNeutron's `steam.exe` tells each game that Steam is running. Anti-cheat
that needs a Windows kernel driver (Easy Anti-Cheat, BattlEye, Vanguard and others) still won't run.

Game logs (`MACNEUTRON_LOG=1`) hide your Steam account ID and login name, and any environment variable whose name
looks like a secret (`…TOKEN…`, `…SECRET…`, `…PASSWORD…`, `…_KEY`); they still contain file paths that name your macOS
user, and Wine's `+steamclient` lines in them can contain your SteamID or persona name: check before posting a log
publicly.

## Upscaling

When a game renders below the size of its window, or below your display's pixel density (Retina screens),
MacNeutron upscales each frame with Apple's MetalFX instead of the blocky stretch macOS would apply. To trade
sharpness for frame rate, pick a lower resolution in the game's windowed or borderless mode. It costs about 1 ms of
GPU time per frame while active and nothing when the game renders at full size; switch "MetalFX upscaling" off for a
game in the Games window if it misbehaves.

## Licences

`wine.app` carries the licence texts of everything in it under `Contents/Resources/licenses/`, and `MacNeutron.app`
carries its own and a pointer to those in `Contents/Resources/licenses/`. The Steam bridge (`lsteamclient`) ships under
Valve's Steamworks SDK licence (`licenses/lsteamclient/`). Provisioning profiles expire: a build signed with an expired
profile stops launching, so a release is rebuilt before its profile runs out.

## Licence

MacNeutron's own code is MIT (`LICENSE`). The patches in `wine-arm64/patches/` keep the licence of the tree they patch:
Wine's and DXMT's are LGPL-2.1+ and FEX's are MIT (details in `wine-arm64/README.md`'s Licences section). The source
archive of a release holds every tree as built.
