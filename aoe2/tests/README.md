# aoe2/tests: the companion repository's tests, against this fork's wine.app (plan R2, N2)

Ported from [Aoe2MacSteamNoRosetta](https://github.com/szotyesz/Aoe2MacSteamNoRosetta) at `f37dfc2`. Each ported file
says so in its first line. That repository has no licence file or licence headers, so there were none to keep.
`m0/runtime.c` also carries that repository's uncommitted R1 review cases (`cpuid`, `x18-stress`, `wait`). Results are
in [`../results/n2.md`](../results/n2.md). Evidence goes under `$AOE2_WORK_ROOT/n2/` (default `~/aoe2-poc-work`).

Every script uses `build/wine-arm64/wine.app` (`MACNEUTRON_ADHOC=1 make wine-arm64` on this Mac) and the pinned
llvm-mingw (`dxmt/toolchain.sh`). Xcode is found through `DEVELOPER_DIR` when the active developer directory is the
Command Line Tools.

| Script | What | Gate |
|---|---|---|
| `p0.sh` | P0 host probes: `platform/capabilities.c` (4K spawn, map at 0x7ffe0000, 4K protection, x18 toggle, TSO on a fresh thread) and `exec-memory/host-vm-probe.c` (RW↔RX transitions required; RWX observed), at 4K and 16K pages. `P0_ENTITLEMENT=managed\|unmanaged\|loader` picks the signature; `loader` is `wine-arm64/wine-adhoc.entitlements` with the hardened runtime | both pass |
| `m0.py [--exec-memory] [--lane arm64\|x64\|both]` | The M0 console suite in two lanes: plain ARM64 PE natively, and the same sources built for x86-64 under FEX. 32 checks per lane; 41 with `--exec-memory` | every check of every lane |
| `wx-scan.sh` | W^X audit: `runtime.exe exec-wait` uses an RWX page and an executable heap, then waits while `vmmap` reads the host process. No region may be writable and executable at once | both lanes |
| `x18-signal/run.sh` | x18 signal stress (R1-X18-RACE): `runtime.exe x18-stress` (syscalls, unix calls, exceptions and suspends, each checking the TEB through x18) while `sigpump` sends SIGUSR1 every N µs | PASS line, exit 0, no crash report |
| `winetest.py --lane arm64\|x64` | Wine's ntdll, kernel32 and kernelbase conformance tests, one unit per process, from a tests-only build of the same patched tree | measurement: lanes compared |
| `verify-no-rosetta.sh <dir> <command…>` | Rule 3: samples every process while `<command>` runs. Fails on the kernel's `P_TRANSLATED` flag, on `oahd`, or on an executable Mach-O without an arm64 slice. `--self-test` checks each kind is caught | wraps the others |

Changes from the companion versions:
- `runtime.c` builds for ARM64 and x86-64. The program counter (`Pc`/`Rip`) and the generated machine code are per
  architecture. x18 is checked only on ARM64; on x86-64 the stress checks the suspended context is a real one.
- Executable-memory cases that need a fixed address take the first free 64 KiB slot at or above 0x60000000 (0x61000000
  for `exec-alloc-state`), found with `VirtualQuery`. Under FEX the companion's literal addresses lie inside a
  committed read-exec region from 0x3ffe0000. Every assertion is unchanged.
- `HOST-NATIVE` no longer reads diagnostics built into the companion's Wine 11.4. It requires every process of a run
  to trace `host page size: 4k` (Wine's `+virtual`), a thin arm64 loader, and no `P_TRANSLATED` flag on the live
  Windows process. The custom-x18 state at the unix boundary is `check.sh x18`'s.

The winetest executables need a second configure of the Wine tree with tests on (the shipped build uses
`--disable-tests`):

```sh
cd build/wine-arm64-src && mkdir -p wine-tests-build && cd wine-tests-build
PATH="$(sh ../../../dxmt/toolchain.sh):$(brew --prefix bison)/bin:$(brew --prefix flex)/bin:$PATH" \
  ../wine/configure --enable-archs=aarch64,x86_64 --with-mingw=llvm-mingw --without-x --without-freetype \
  --without-gnutls CC=/usr/bin/clang CXX=/usr/bin/clang++
for m in ntdll kernel32 kernelbase; do for a in aarch64 x86_64; do set -- "$@" dlls/$m/tests/$a-windows/${m}_test.exe; done; done
make -j10 "$@"
```
