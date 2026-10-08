.PHONY: build test smoke app release bridge bridge-check presenter presenter-check dxmt-tests dxmt-tests-arm64ec dxmt-check dxil-corpus wine-arm64 wine-arm64-export wine-arm64-tests wine-arm64-check

APP = build/MacNeutron.app
# Every Windows-side binary is built with the pinned llvm-mingw (Clang); dxmt/toolchain.sh fetches it once.
MINGW_BIN = $(shell sh dxmt/toolchain.sh)
MINGW = $(MINGW_BIN)/x86_64-w64-mingw32-clang -O2 -static -s
MINGWXX = $(MINGW_BIN)/x86_64-w64-mingw32-clang++ -O2 -static -s
MINGW_A64 = $(MINGW_BIN)/aarch64-w64-mingw32-clang -O2 -static -s
BRIDGE = build/bridge
PRESENTER = build/presenter

build:
	swift build -c release

test:
	swift test

# The launcher on wine.app in a tool folder assembled with `macneutron install`, and the install itself (gates L5,
# L6; real Wine, no Steam). See Tests/Smoke/smoke.sh.
smoke: build bridge wine-arm64
	sh Tests/Smoke/smoke.sh

# The Steam bridge (docs/superpowers/specs/2026-09-28-macneutron-steam-bridge-design.md): steam.exe and its test
# helper for the arm64 runtime in $(BRIDGE)/arm64, and the x64 steamprobe.exe, which runs under FEX.
bridge:
	mkdir -p $(BRIDGE)/arm64/tests
	$(MINGW) -fms-extensions -o $(BRIDGE)/steamprobe.exe bridge/probe.c
	$(MINGW_A64) -o $(BRIDGE)/arm64/steam.exe bridge/steam.c -ladvapi32
	$(MINGW_A64) -o $(BRIDGE)/arm64/tests/helper.exe bridge/tests/helper.c -ladvapi32 -lshell32

# steam.exe on wine.app, directly and through the launcher (real Wine, no Steam).
bridge-check: build bridge wine-arm64
	sh bridge/probe.sh --redact-self-test
	sh bridge/check.sh

# The MetalFX presenter's test program. The presenter itself is built into wine.app (wine-arm64/build.sh), where
# winemetal.so loads it.
presenter:
	mkdir -p $(PRESENTER)
	$(MINGW) -o $(PRESENTER)/present_loop.exe presenter/tests/present_loop.c -ld3d11 -ldxgi -luser32 -lgdi32 -ldxguid -luuid

# The presenter in wine.app through the launcher on DXMT (real Wine, no Steam).
presenter-check: build wine-arm64 presenter
	sh presenter/check.sh

# D3D12 test programs for our DXMT, built in parallel (one compiler per core).
DXMT_TESTS = $(patsubst dxmt/tests/%.cpp,build/dxmt-tests/%.exe,$(wildcard dxmt/tests/d3d12_*.cpp))
dxmt-tests:
	mkdir -p build/dxmt-tests
	$(MAKE) -s -j$(shell sysctl -n hw.ncpu) $(DXMT_TESTS)
build/dxmt-tests/%.exe: dxmt/tests/%.cpp dxmt/tests/d3d12_common.hpp
	$(MINGWXX) -std=c++17 -o $@ $< -ld3d12 -ldxgi -luser32 -lpsapi

# The same programs and present_loop for ARM64EC, for the arm64 runtime (arm64 DXMT spec §7), built in parallel.
MINGW_EC = $(MINGW_BIN)/arm64ec-w64-mingw32-clang -O2 -static -s
MINGWXX_EC = $(MINGW_BIN)/arm64ec-w64-mingw32-clang++ -O2 -static -s
DXMT_TESTS_EC = $(patsubst dxmt/tests/%.cpp,build/dxmt-tests-arm64ec/%.exe,$(wildcard dxmt/tests/d3d12_*.cpp)) \
	build/dxmt-tests-arm64ec/present_loop.exe
dxmt-tests-arm64ec:
	mkdir -p build/dxmt-tests-arm64ec
	$(MAKE) -s -j$(shell sysctl -n hw.ncpu) $(DXMT_TESTS_EC)
build/dxmt-tests-arm64ec/%.exe: dxmt/tests/%.cpp dxmt/tests/d3d12_common.hpp
	$(MINGWXX_EC) -std=c++17 -o $@ $< -ld3d12 -ldxgi -luser32 -lpsapi
build/dxmt-tests-arm64ec/present_loop.exe: presenter/tests/present_loop.c
	$(MINGW_EC) -o $@ $< -ld3d11 -ldxgi -luser32 -lgdi32 -ldxguid -luuid

# Translate a folder of captured DXIL shaders offline (DIR=~/dxil-smite2); never commit a game's shaders.
dxil-corpus: wine-arm64
	build/wine-arm64/dxil-translate "$(DIR)"

# Our DXMT in wine.app through the launcher against D3DMetal in the frozen Rosetta reference
# (tools/freeze-rosetta-reference.sh), with the x64 test programs under FEX, then the ARM64EC ones (real Wine, no
# Steam); see dxmt/check.sh.
dxmt-check: build wine-arm64 dxmt-tests dxmt-tests-arm64ec presenter
	sh dxmt/tests/build_test.sh
	sh dxmt/check.sh
	MACNEUTRON_ARM64_TESTS=build/dxmt-tests-arm64ec MACNEUTRON_ARM64_LOOP=build/dxmt-tests-arm64ec/present_loop.exe DXMT_CHECK_WORK="$${TMPDIR:-/tmp}/macneutron dxmt arm64ec" sh dxmt/check.sh

# A development MacNeutron.app, ad hoc signed, with the CLI, wine.app and steam.exe inside. Never open it on this Mac:
# its start installs into the real tool folder. Needs the signing variables (it builds wine.app); make release
# builds the notarized one.
app: build bridge wine-arm64
	@! ps -axo comm= | LC_ALL=C /usr/bin/grep -qF "$(abspath $(APP))/" || { echo 'app: quit the MacNeutron running from $(APP) first' >&2; exit 1; }
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Helpers $(APP)/Contents/Resources
	cp App/Info.plist $(APP)/Contents/Info.plist
	cp .build/release/MacNeutronApp $(APP)/Contents/MacOS/MacNeutron
	cp .build/release/macneutron $(APP)/Contents/Helpers/macneutron
	codesign --force --sign - $(APP)/Contents/Helpers/macneutron
	cp -c -R build/wine-arm64/wine.app $(APP)/Contents/Helpers/wine.app
	cp $(BRIDGE)/arm64/steam.exe $(APP)/Contents/Resources/steam.exe
	codesign --force --sign - $(APP)

# The release: notarized MacNeutron.app, its zip and the source archive (spec §6.3). VERSION=x.y.z; needs the
# signing and notary variables and the network. A bad VERSION stops it before anything is built.
release:
	@sh release/release.sh --check-version "$(VERSION)"
	$(MAKE) build bridge wine-arm64
	sh release/release.sh "$(VERSION)"

# Native arm64 Wine 11.19 with our patches, FEX for x64 code and our DXMT for ARM64X
# (docs/superpowers/specs/2026-10-02-macneutron-native-arm64-design.md §5, §6; 2026-10-03-macneutron-arm64-dxmt-design.md).
# First run: shallow clones of Wine, FEX and DXMT, an arm64 LLVM build and some compiling; see wine-arm64/build.sh.
wine-arm64:
	sh wine-arm64/build.sh

# Commits made in build/wine-arm64-src/wine, fex and dxmt back into wine-arm64/patches/wine, fex and dxmt.
wine-arm64-export:
	sh wine-arm64/export.sh

# Test programs for the arm64 stack, built in parallel. The file name's prefix picks the compiler (arm64-, arm64ec-,
# x64-); a program that needs more flags sets WA_FLAGS_<name> (arm64ec-viewec: -lonecore), which comes last. x64-bench, a
# benchmark (gate G4), is built -O2: the later -O wins. winshot is a Mac program: it reads a window's pixels off the screen.
WA_TESTS = $(patsubst wine-arm64/tests/%.c,build/wine-arm64-tests/%.exe,$(wildcard wine-arm64/tests/*.c)) \
	$(patsubst wine-arm64/tests/%.cpp,build/wine-arm64-tests/%.exe,$(wildcard wine-arm64/tests/*.cpp))
WA_FLAGS = -O1 -fms-extensions -D_WIN32_WINNT=0x0A00
WA_FLAGS_arm64ec-viewec = -lonecore
WA_FLAGS_x64-bench = -O2
WA_FLAGS_arm64-fonts-tls = -lgdi32 -lsecur32 -ldwrite -lcrypt32
WA_FLAGS_arm64-x18v = -lntdll
WA_FLAGS_arm64-x18path = -lntdll
WA_FLAGS_arm64ec-futexterm = -lsynchronization
WA_FLAGS_arm64ec-waitaddr = -lsynchronization
WA_FLAGS_arm64ec-suspendwake = -lsynchronization
WA_FLAGS_arm64ec-d3d11a8 = -ld3d11 -ldxguid -luuid
WA_FLAGS_arm64ec-d3d11lod = -ld3d11 -ldxguid -luuid
WA_FLAGS_arm64ec-d3d11packed = -ld3d11 -ldxguid -luuid
WA_FLAGS_arm64ec-d3d11ramp = -ld3d11 -ldxguid -luuid
WA_FLAGS_arm64ec-d3d11upload = -ld3d11 -ldxguid -luuid
wine-arm64-tests:
	mkdir -p build/wine-arm64-tests
	$(MAKE) -s -j$(shell sysctl -n hw.ncpu) $(WA_TESTS) build/wine-arm64-tests/x64-x18path.exe \
		build/wine-arm64-tests/x64-globalroot.exe build/wine-arm64-tests/x64-futexterm.exe build/wine-arm64-tests/x64-waitaddr.exe \
		build/wine-arm64-tests/x64-suspendwake.exe build/wine-arm64-tests/x64-timerreset.exe build/wine-arm64-tests/winshot
build/wine-arm64-tests/arm64-%.exe: wine-arm64/tests/arm64-%.c
	$(MINGW_BIN)/aarch64-w64-mingw32-clang $(WA_FLAGS) -o $@ $< $(WA_FLAGS_$(basename $(@F)))
build/wine-arm64-tests/arm64ec-%.exe: wine-arm64/tests/arm64ec-%.c
	$(MINGW_BIN)/arm64ec-w64-mingw32-clang $(WA_FLAGS) -o $@ $< $(WA_FLAGS_$(basename $(@F)))
build/wine-arm64-tests/x64-%.exe: wine-arm64/tests/x64-%.c
	$(MINGW_BIN)/x86_64-w64-mingw32-clang $(WA_FLAGS) -o $@ $< $(WA_FLAGS_$(basename $(@F)))
build/wine-arm64-tests/x64-%.exe: wine-arm64/tests/x64-%.cpp
	$(MINGW_BIN)/x86_64-w64-mingw32-clang++ $(WA_FLAGS) -static -o $@ $< $(WA_FLAGS_$(basename $(@F)))
# arm64-x18path's source built for x64 too: its paths under FEX (ship-base spec §9, T2).
build/wine-arm64-tests/x64-x18path.exe: wine-arm64/tests/arm64-x18path.c
	$(MINGW_BIN)/x86_64-w64-mingw32-clang $(WA_FLAGS) -o $@ $< $(WA_FLAGS_arm64-x18path)
# arm64-globalroot's source built for x64 too: the file opens AoE2DE's anti-tamper makes, under FEX (aoe2 patch 23).
build/wine-arm64-tests/x64-globalroot.exe: wine-arm64/tests/arm64-globalroot.c
	$(MINGW_BIN)/x86_64-w64-mingw32-clang $(WA_FLAGS) -o $@ $<
# arm64ec-futexterm's source built for x64 too: a waiter terminated by another thread, under FEX (aoe2 patch 24).
build/wine-arm64-tests/x64-futexterm.exe: wine-arm64/tests/arm64ec-futexterm.c
	$(MINGW_BIN)/x86_64-w64-mingw32-clang $(WA_FLAGS) -o $@ $< $(WA_FLAGS_arm64ec-futexterm)
# arm64ec-waitaddr's source built for x64 too: WaitOnAddress semantics under FEX (aoe2 patch 25).
build/wine-arm64-tests/x64-waitaddr.exe: wine-arm64/tests/arm64ec-waitaddr.c
	$(MINGW_BIN)/x86_64-w64-mingw32-clang $(WA_FLAGS) -o $@ $< $(WA_FLAGS_arm64ec-waitaddr)
# arm64ec-suspendwake's source built for x64 too: a wake with the contending threads suspended, under FEX (aoe2 patch 25).
build/wine-arm64-tests/x64-suspendwake.exe: wine-arm64/tests/arm64ec-suspendwake.c
	$(MINGW_BIN)/x86_64-w64-mingw32-clang $(WA_FLAGS) -o $@ $< $(WA_FLAGS_arm64ec-suspendwake)
# arm64ec-timerreset's source built for x64 too: waitable timers and the threadpool's timer thread, under FEX (aoe2 patch 26).
build/wine-arm64-tests/x64-timerreset.exe: wine-arm64/tests/arm64ec-timerreset.c
	$(MINGW_BIN)/x86_64-w64-mingw32-clang $(WA_FLAGS) -o $@ $<
build/wine-arm64-tests/winshot: wine-arm64/tools/winshot.c
	/usr/bin/clang -O1 -o $@ $< -framework CoreGraphics -framework ImageIO -framework CoreFoundation

# The arm64 runtime on this Mac: boots, runs native ARM64 code, leaves nothing behind (spec §7.3). Needs
# MACNEUTRON_SIGN_IDENTITY and MACNEUTRON_PROVISIONING_PROFILE (the build signs the runtime), and the frozen Rosetta
# reference (MACNEUTRON_REFERENCE, tools/freeze-rosetta-reference.sh): gate G4's baseline runs on its own launcher,
# and the dxmt-* steps' D3DMetal reference is its GPTK (dxmt/check.sh).
wine-arm64-check: build bridge wine-arm64 wine-arm64-tests dxmt-tests presenter dxmt-tests-arm64ec
	sh wine-arm64/tests/mode_test.sh
	sh wine-arm64/tests/profile_test.sh
	sh wine-arm64/tests/licences_test.sh build/wine-arm64/wine.app
	sh wine-arm64/tests/licences_test.sh --self-test build/wine-arm64/wine.app
	sh wine-arm64/check.sh
