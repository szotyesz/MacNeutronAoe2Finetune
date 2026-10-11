#!/bin/sh
# Builds MacNeutron's arm64 Wine (11.19 + wine-arm64/patches/wine) into build/wine-arm64-src/wine-build, against
# FreeType and gnutls built from wine-arm64/deps.pins' tarballs into deps, FEX (+ wine-arm64/patches/fex) into fex-ec
# and fex-unixlib, DXMT (dxmt/pins' commit + wine-arm64/patches/dxmt) for ARM64X into dxmt-install, and Proton's
# lsteamclient (deps.pins' commit + wine-arm64/patches/lsteamclient) as one of Wine's DLLs, and the Vulkan stack of
# wine-arm64/vulkan.pins (the Vulkan loader, KosmicKrisp + wine-arm64/patches/mesa, DXVK as ARM64EC), then
# stages the signed build/wine-arm64/wine.app (native arm64 spec §5.4, §6.3; arm64 DXMT spec §4; ship-base spec §5, §7). Never installs
# tools. Needs MACNEUTRON_SIGN_IDENTITY and MACNEUTRON_PROVISIONING_PROFILE, or MACNEUTRON_ADHOC=1 on a Mac with SIP
# and AMFI off (lib.sh). BUILD_DIR replaces build/ (tests).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/wine-arm64/pins"
. "$ROOT/dxmt/pins"  # DXMT_REPO, DXMT_COMMIT, LLVM_TAG: the Rosetta stack's pin, shared
. "$ROOT/wine-arm64/deps.pins"
. "$ROOT/wine-arm64/vulkan.pins"
. "$ROOT/wine-arm64/lib.sh"
FETCH_TAG=wine-arm64
. "$ROOT/dxmt/fetch.sh"
. "$ROOT/dxmt/llvm.sh"
B="${BUILD_DIR:-$ROOT/build}"
SRC="$B/wine-arm64-src"
OUT="$B/wine-arm64"
W="$SRC/wine"
F="$SRC/fex"
D="$SRC/dxmt"
LSC="$SRC/lsteamclient"
VH="$SRC/vulkan-headers"
VL="$SRC/vulkan-loader"
M="$SRC/mesa"
X="$SRC/dxvk"
DEPS="$SRC/deps"
# What each tree was patched to, kept outside it so they never count as changes: <repo>.applied, HEAD after the
# patches went on, and <repo>.series, the hash of the series (pins and patches) that went on. A tree at that HEAD with
# another series is started over.
PATCHES="$ROOT/wine-arm64/patches/wine"
FEX_PATCHES="$ROOT/wine-arm64/patches/fex"
DXMT_PATCHES="$ROOT/wine-arm64/patches/dxmt"
LSC_PATCHES="$ROOT/wine-arm64/patches/lsteamclient"
KK_PATCHES="$ROOT/wine-arm64/patches/mesa"
NO_PATCHES="$ROOT/wine-arm64/patches/none"  # the Vulkan headers', the loader's and DXVK's: none

# 1. Tools, all named at once. bison and flex are keg-only: Homebrew's go first on PATH. The build doesn't run autoconf;
#    the development loop does, for a patch that changes configure.ac (README).
need_tool autoconf autoconf; need_tool bison bison keg; need_tool flex flex keg; need_tool cmake cmake
need_tool ninja ninja; need_tool meson meson; need_tool pkg-config pkg-config
need_tool msgfmt gettext  # without it Wine's configure only warns, and the bundle has no translations
# DXMT compiles its own Metal shaders; Xcode ships the compiler as a separate component.
xcrun metal --version > /dev/null 2>&1 || missing="$missing, Metal Toolchain (xcodebuild -downloadComponent MetalToolchain)"
# KosmicKrisp's build-time compilers (mesa_clc and two more, step 7b) link LLVM, Clang and the SPIR-V translator:
# Homebrew's, one major version, at build time only (the driver links none of them). llvm is keg-only: its llvm-config
# is named to Mesa, never put on PATH, where its clang would shadow Apple's. Python 3 runs Mesa's generators.
LLVM_CONFIG="$(brew --prefix llvm 2> /dev/null || true)/bin/llvm-config"
[ -x "$LLVM_CONFIG" ] || missing="$missing, llvm-config (brew install llvm)"
SPIRV_PC="$(brew --prefix spirv-llvm-translator 2> /dev/null || true)/lib/pkgconfig"
[ -f "$SPIRV_PC/LLVMSPIRVLib.pc" ] || missing="$missing, LLVMSPIRVLib (brew install spirv-llvm-translator)"
need_tool python3 python
die_if_missing
v1=$("$LLVM_CONFIG" --version | cut -d . -f 1) v2=$(sed -n 's/^Version: *\([0-9]*\).*/\1/p' "$SPIRV_PC/LLVMSPIRVLib.pc")
[ "$v1" = "$v2" ] || die "Homebrew's llvm is $v1 but its spirv-llvm-translator is for LLVM $v2: brew upgrade both"
check_signing  # before anything is fetched or built
# llvm-mingw's arm64ec- and aarch64-w64-mingw32 wrappers, for the Windows side of Wine.
PATH="$(sh "$ROOT/dxmt/toolchain.sh"):$PATH"
export PATH
export MACOSX_DEPLOYMENT_TARGET=27.0

# 2. Fetch and patch, once per series. A tree with work in it is never touched; a clean one follows the patches.
# patch_tree <tmp-tree> <repo> <patch-dir> <series> <base>: git am the series on branch macneutron, record it, and
# move the tree into place. Recorded before the move: a stop in between leaves no tree, so it's redone.
patch_tree() {
  for p in "$3"/*.patch; do
    [ -e "$p" ] || continue  # a tree without patches ($NO_PATCHES)
    git -C "$1" am -q "$p" || { git -C "$1" am --abort; die "patch $(basename "$p") does not apply to $5"; }
  done
  git -C "$1" rev-parse HEAD > "$SRC/$2.applied"
  echo "$4" > "$SRC/$2.series"
  mv "$1" "$SRC/$2"
}
fetch_wine() {
  echo "wine-arm64: fetching Wine $WINE_TAG" >&2
  rm -rf "$W.tmp" "$SRC/wine-build"  # a new tree gets a new build folder
  git clone -q -c advice.detachedHead=false --depth 1 --branch "$WINE_TAG" "$WINE_REPO" "$W.tmp" \
    || die "can't clone $WINE_REPO at $WINE_TAG"
  [ "$(git -C "$W.tmp" rev-parse HEAD)" = "$WINE_COMMIT" ] || die "$WINE_TAG is not $WINE_COMMIT in $WINE_REPO"
  git -C "$W.tmp" checkout -q -b macneutron
  patch_tree "$W.tmp" wine "$PATCHES" "$wine_series" "$WINE_COMMIT"
}
# FEX's main has moved past the pin, so a shallow clone can't reach it: fetch the one commit.
fetch_fex() {
  echo "wine-arm64: fetching FEX $FEX_COMMIT" >&2
  rm -rf "$F.tmp" "$SRC/fex-ec" "$SRC/fex-unixlib"
  git init -q "$F.tmp"
  git -C "$F.tmp" remote add origin "$FEX_REPO"
  git -C "$F.tmp" fetch -q --depth 1 origin "$FEX_COMMIT" || die "can't fetch $FEX_COMMIT from $FEX_REPO"
  git -C "$F.tmp" checkout -q -b macneutron FETCH_HEAD
  git -C "$F.tmp" submodule update -q --init --recursive --depth 1 || die "can't fetch FEX's submodules"
  patch_tree "$F.tmp" fex "$FEX_PATCHES" "$fex_series" "$FEX_COMMIT"
}
# DXMT's own clone (the Rosetta stack's build/dxmt-src/dxmt is never touched), fetched like FEX's.
fetch_dxmt() {
  echo "wine-arm64: fetching DXMT $DXMT_COMMIT" >&2
  rm -rf "$D.tmp" "$SRC/dxmt-build" "$SRC/dxmt-install"
  git init -q "$D.tmp"
  git -C "$D.tmp" remote add origin "$DXMT_REPO"
  git -C "$D.tmp" fetch -q --depth 1 origin "$DXMT_COMMIT" || die "can't fetch $DXMT_COMMIT from $DXMT_REPO"
  git -C "$D.tmp" checkout -q -b macneutron FETCH_HEAD
  git -C "$D.tmp" submodule update -q --init --depth 1 || die "can't fetch DXMT's submodules"
  patch_tree "$D.tmp" dxmt "$DXMT_PATCHES" "$dxmt_series" "$DXMT_COMMIT"
}
# Proton's lsteamclient/ alone (ship-base spec §7): the one commit, blob-filtered, checked out sparse without the
# Steamworks SDK folders and the generator. Git fetches the blobs it checks out from Proton, so lazy fetching is on.
fetch_lsteamclient() {
  echo "wine-arm64: fetching lsteamclient $LSTEAMCLIENT_COMMIT" >&2
  unset GIT_NO_LAZY_FETCH
  rm -rf "$LSC.tmp"
  git init -q "$LSC.tmp"
  git -C "$LSC.tmp" remote add origin "$LSTEAMCLIENT_REPO"
  git -C "$LSC.tmp" fetch -q --depth 1 --filter=blob:none origin "$LSTEAMCLIENT_COMMIT" \
    || die "can't fetch $LSTEAMCLIENT_COMMIT from $LSTEAMCLIENT_REPO"
  git -C "$LSC.tmp" sparse-checkout set --no-cone '/lsteamclient/' '!/lsteamclient/steamworks_sdk_*/' \
    '!/lsteamclient/gen_wrapper.py' || die "can't set lsteamclient's sparse checkout"
  git -C "$LSC.tmp" checkout -q -b macneutron FETCH_HEAD || die "can't check out lsteamclient/ from $LSTEAMCLIENT_REPO"
  patch_tree "$LSC.tmp" lsteamclient "$LSC_PATCHES" "$lsc_series" "$LSTEAMCLIENT_COMMIT"
}
# fetch_commit <tree> <name> <repo> <commit> <series> <patch-dir> [submodules]: the one commit of <repo>, as FEX's, then
# its patches; the tree's build folders go with the old tree.
fetch_commit() {
  echo "wine-arm64: fetching $2 $4" >&2
  rm -rf "$SRC/$1.tmp"
  git init -q "$SRC/$1.tmp"
  git -C "$SRC/$1.tmp" remote add origin "$3"
  git -C "$SRC/$1.tmp" fetch -q --depth 1 origin "$4" || die "can't fetch $4 from $3"
  git -C "$SRC/$1.tmp" checkout -q -b macneutron FETCH_HEAD
  if [ -n "${7:-}" ]; then
    git -C "$SRC/$1.tmp" submodule update -q --init --recursive --depth 1 || die "can't fetch $2's submodules"
  fi
  patch_tree "$SRC/$1.tmp" "$1" "$6" "$5" "$4"
}
fetch_vulkan_headers() {
  rm -rf "$SRC/vulkan-install"
  fetch_commit vulkan-headers "the Vulkan headers" "$VULKAN_HEADERS_REPO" "$VULKAN_HEADERS_COMMIT" \
    "$vulkan_headers_series" "$NO_PATCHES"
}
fetch_vulkan_loader() {
  rm -rf "$SRC/vulkan-loader-build" "$SRC/vulkan-install"
  fetch_commit vulkan-loader "the Vulkan loader" "$VULKAN_LOADER_REPO" "$VULKAN_LOADER_COMMIT" "$vulkan_loader_series" \
    "$NO_PATCHES"
}
fetch_mesa() {
  rm -rf "$SRC/mesa-tools" "$SRC/mesa-build"
  fetch_commit mesa "Mesa (KosmicKrisp)" "$MESA_REPO" "$MESA_COMMIT" "$mesa_series" "$KK_PATCHES"
}
# DXVK's tag, checked against its commit, and its submodules (headers, dxbc-spirv, libdisplay-info).
fetch_dxvk() {
  echo "wine-arm64: fetching DXVK $DXVK_TAG" >&2
  rm -rf "$X.tmp" "$SRC/dxvk-build" "$SRC/dxvk-install"
  git clone -q -c advice.detachedHead=false --depth 1 --branch "$DXVK_TAG" "$DXVK_REPO" "$X.tmp" \
    || die "can't clone $DXVK_REPO at $DXVK_TAG"
  [ "$(git -C "$X.tmp" rev-parse HEAD)" = "$DXVK_COMMIT" ] || die "$DXVK_TAG is not $DXVK_COMMIT in $DXVK_REPO"
  git -C "$X.tmp" checkout -q -b macneutron
  git -C "$X.tmp" submodule update -q --init --recursive --depth 1 || die "can't fetch DXVK's submodules"
  patch_tree "$X.tmp" dxvk "$NO_PATCHES" "$dxvk_series" "$DXVK_COMMIT"
}
wine_series=$(tree_series wine)
fex_series=$(tree_series fex)
dxmt_series=$(tree_series dxmt)
lsc_series=$(tree_series lsteamclient)
vulkan_headers_series=$(tree_series vulkan-headers)
vulkan_loader_series=$(tree_series vulkan-loader)
mesa_series=$(tree_series mesa)
dxvk_series=$(tree_series dxvk)
# Every build input, once: the up-to-date check and the stamp written at the end must agree.
stamp=$(stamp_of "$ROOT/wine-arm64/pins" "$PATCHES"/*.patch "$FEX_PATCHES"/*.patch "$ROOT/wine-arm64/build.sh" \
  "$ROOT/wine-arm64/lib.sh" "$ROOT/wine-arm64/bundle.sh" "$ROOT/wine-arm64/wine.entitlements" \
  "$ROOT/wine-arm64/wine-adhoc.entitlements" "$ROOT/wine-arm64/Info.plist" "$ROOT/dxmt/pins" "$DXMT_PATCHES"/*.patch \
  "$ROOT/dxmt/llvm.sh" "$ROOT/dxmt/tools/dxil-probe.cpp" "$ROOT/dxmt/tools/dxil-translate.mm" "$ROOT/wine-arm64/licenses/NOTICES.md" \
  "$ROOT/wine-arm64/licenses/README" "$ROOT/wine-arm64/tests/licences_test.sh" "$ROOT/wine-arm64/deps.pins" \
  "$ROOT/dxmt/fetch.sh" "$ROOT/wine-arm64/x18-allow.txt" "$ROOT/wine-arm64/tools/x18scan.sh" "$LSC_PATCHES"/*.patch \
  "$ROOT/presenter/present.m" "$ROOT/LICENSE" "$ROOT/wine-arm64/tools/xcrun-metal.sh" "$ROOT/wine-arm64/vulkan.pins" \
  "$KK_PATCHES"/*.patch)
mkdir -p "$SRC"
wine_mode=$(build_mode "$W" "$SRC/wine.applied" "$SRC/wine.series" "$wine_series")
fex_mode=$(build_mode "$F" "$SRC/fex.applied" "$SRC/fex.series" "$fex_series")
dxmt_mode=$(build_mode "$D" "$SRC/dxmt.applied" "$SRC/dxmt.series" "$dxmt_series")
lsteamclient_mode=$(build_mode "$LSC" "$SRC/lsteamclient.applied" "$SRC/lsteamclient.series" "$lsc_series")
vulkan_headers_mode=$(build_mode "$VH" "$SRC/vulkan-headers.applied" "$SRC/vulkan-headers.series" \
  "$vulkan_headers_series")
vulkan_loader_mode=$(build_mode "$VL" "$SRC/vulkan-loader.applied" "$SRC/vulkan-loader.series" "$vulkan_loader_series")
mesa_mode=$(build_mode "$M" "$SRC/mesa.applied" "$SRC/mesa.series" "$mesa_series")
dxvk_mode=$(build_mode "$X" "$SRC/dxvk.applied" "$SRC/dxvk.series" "$dxvk_series")
# prepare <repo> <mode>: a tree that isn't there yet, or was patched with another series, is fetched and patched.
# <repo> names fetch_<repo>; its folder is <repo> with "-" for "_" (vulkan_headers: vulkan-headers).
prepare() {
  case "$2" in
    reapply) echo "wine-arm64: $1's patch series changed, re-applying" >&2; rm -rf "${SRC:?}/$(echo "$1" | tr _ -)" ;;
    pinned) ;;
    *) return 0 ;;
  esac
  rm -f "$OUT/version"
  "fetch_$1"
}
prepare wine "$wine_mode"
prepare fex "$fex_mode"
prepare dxmt "$dxmt_mode"
prepare lsteamclient "$lsteamclient_mode"
prepare vulkan_headers "$vulkan_headers_mode"
prepare vulkan_loader "$vulkan_loader_mode"
prepare mesa "$mesa_mode"
prepare dxvk "$dxvk_mode"
# lsteamclient builds as one of Wine's DLLs (Wine patch 0016 registers it): its folder is linked in as
# dlls/lsteamclient, which the Wine tree ignores, so that tree stays applied and lsteamclient's source never enters a
# Wine patch. Every build: a fetched Wine tree has neither. The ignore goes first, so the link never shows as a change.
LC_ALL=C /usr/bin/grep -qx /dlls/lsteamclient "$W/.git/info/exclude" 2> /dev/null \
  || echo /dlls/lsteamclient >> "$W/.git/info/exclude"
ln -sfn ../../lsteamclient/lsteamclient "$W/dlls/lsteamclient"
# The repository commit the bundle's SOURCE names (step 8). Dirty when anything the build reads from the repository
# differs from that commit, a new file included.
mac=$(git -C "$ROOT" rev-parse HEAD)
[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=normal -- wine-arm64 dxmt bridge Makefile presenter \
  LICENSE)" ] || mac="$mac+dirty"
# The build is a development build if any tree is.
if [ "$wine_mode" = development ] || [ "$fex_mode" = development ] || [ "$dxmt_mode" = development ] \
  || [ "$lsteamclient_mode" = development ] || [ "$vulkan_headers_mode" = development ] \
  || [ "$vulkan_loader_mode" = development ] || [ "$mesa_mode" = development ] || [ "$dxvk_mode" = development ]; then
  echo "wine-arm64: development build" >&2
  rm -f "$OUT/version"  # what gets built is not what the stamp describes; the next applied build redoes it
  dev=1
else
  dev=
  # A bundle staged from a dirty tree whose changes are now committed has the same stamp: bundled again, once, so its
  # SOURCE names the commit.
  if [ "$(cat "$OUT/version" 2> /dev/null)" = "$stamp" ] && [ -d "$OUT/wine.app" ] && { [ "${mac%+dirty}" != "$mac" ] \
    || ! LC_ALL=C /usr/bin/grep -q '^MACNEUTRON_COMMIT=.*+dirty$' "$OUT/wine.app/Contents/Resources/licenses/SOURCE"; }
  then
    echo "wine-arm64: up to date" >&2
    exit 0
  fi
fi

# 3. FreeType and gnutls (ship-base spec §5), which Wine dlopens, from the pinned tarballs into $DEPS: gmp and nettle
#    static and folded into libgnutls.30.dylib, FreeType without PNG, HarfBuzz or Brotli. Nothing outside /usr/lib and
#    /System gets in: pkg-config sees only $DEPS. Redone when the tarballs' pins, the configure options or the step's
#    environment and commands change (their hash is deps/.complete); deps-src stays, bundle.sh copies the licence texts
#    from it.
DEPS_TARS="gmp:$GMP_URL nettle:$NETTLE_URL gnutls:$GNUTLS_URL freetype:$FREETYPE_URL"  # <name>:<url>, build order
fetch "$GMP_URL" "$SRC/${GMP_URL##*/}" "$GMP_SHA256"
fetch "$NETTLE_URL" "$SRC/${NETTLE_URL##*/}" "$NETTLE_SHA256"
fetch "$GNUTLS_URL" "$SRC/${GNUTLS_URL##*/}" "$GNUTLS_SHA256"
fetch "$FREETYPE_URL" "$SRC/${FREETYPE_URL##*/}" "$FREETYPE_SHA256"
conf_gmp="--enable-static --disable-shared --with-pic"
conf_nettle="--enable-static --disable-shared --disable-documentation"  # PIC is nettle's default
conf_gnutls="--enable-shared --disable-static --sysconfdir=/etc --with-included-libtasn1 --with-included-unistring
  --without-p11-kit --without-idn --without-tpm --without-tpm2 --without-zlib --without-brotli --without-zstd
  --without-leancrypto --disable-nls --disable-tools --disable-cxx --disable-doc --disable-tests --disable-libdane"
conf_freetype="--enable-shared --disable-static --without-png --without-harfbuzz --without-brotli --with-zlib=yes
  --with-bzip2=yes"
# The step's environment, its build of one library (in deps-src/<name>, with the options as "$@") and what each built
# dylib gets after: kept as text, which is both run (eval) and hashed. The text, not its expansion: $DEPS is where
# .complete lives, and the CPU count is no input.
# shellcheck disable=SC2016  # expanded by eval
deps_env='CC=/usr/bin/clang PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig" CPPFLAGS="-I$DEPS/include" LDFLAGS="-L$DEPS/lib"'
# shellcheck disable=SC2016
deps_make='./configure --prefix="$DEPS" "$@" && make -j"$(sysctl -n hw.ncpu)" && make install'
# shellcheck disable=SC2016
deps_post='strip -S "$f" && install_name_tool -id "@rpath/lib$l.dylib" "$f"'
deps_in=$({ deps_pins; echo "MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET"; echo "$deps_env"; echo "$deps_make"
  echo "$deps_post"; echo "$conf_gmp"; echo "$conf_nettle"; echo "$conf_gnutls"; echo "$conf_freetype"; } \
  | shasum -a 256 | cut -d ' ' -f 1)
# build_dep <name> <configure options...>: configure, make and install one library from deps-src/<name>.
build_dep() {
  n=$1; shift
  echo "wine-arm64: building $n (log: $SRC/deps-$n.log)" >&2
  ( cd "$SRC/deps-src/$n" && eval "$deps_make" ) > "$SRC/deps-$n.log" 2>&1 \
    || die "building $n failed; see $SRC/deps-$n.log"
}
unpack() {  # unpack <name>:<url>: the tarball into deps-src/<name>, through <name>.tmp so a stop leaves none
  rm -rf "$SRC/deps-src/${1%%:*}.tmp"
  mkdir -p "$SRC/deps-src/${1%%:*}.tmp"
  tar -xf "$SRC/${1##*/}" -C "$SRC/deps-src/${1%%:*}.tmp" --strip-components 1 || die "can't unpack ${1##*/}"
  mv "$SRC/deps-src/${1%%:*}.tmp" "$SRC/deps-src/${1%%:*}"
}
if [ "$(cat "$DEPS/.complete" 2> /dev/null)" = "$deps_in" ]; then
  echo "wine-arm64: FreeType and gnutls are up to date" >&2
  for t in $DEPS_TARS; do  # bundle.sh copies the licence texts from deps-src
    [ -d "$SRC/deps-src/${t%%:*}" ] || { echo "wine-arm64: unpacking ${t##*/} again" >&2; unpack "$t"; }
  done
else
  rm -rf "$DEPS" "$SRC/deps-src"
  for t in $DEPS_TARS; do unpack "$t"; done
  (
    eval "export $deps_env"
    unset PKG_CONFIG_PATH CPATH LIBRARY_PATH CFLAGS CXXFLAGS  # the compiler's own search paths stay the SDK's
    # shellcheck disable=SC2086  # the options are lists
    { build_dep gmp $conf_gmp; build_dep nettle $conf_nettle; build_dep gnutls $conf_gnutls
      build_dep freetype $conf_freetype; }
  )
  # The shipped form: no debug symbols (they name the build folder), found by @rpath beside the .so files that load
  # it. Then what it links: /usr/lib and /System only (after otool -L's file and ID lines). A failure names the log.
  for l in freetype.6 gnutls.30; do
    f="$DEPS/lib/lib$l.dylib" log="$SRC/deps-${l%.*}.log"
    eval "$deps_post" || die "can't strip ${f##*/} or set its install name"
    out=$(otool -L "$f" | tail -n +3 | awk '{ print $1 }' | LC_ALL=C /usr/bin/grep -vE '^(/usr/lib/|/System/)' || true)
    [ -z "$out" ] || die "${f##*/} depends on $(echo "$out" | tr '\n' ' ')(see $log)"
  done
  out=$(otool -L "$DEPS/lib/libgnutls.30.dylib" | tail -n +3 | LC_ALL=C /usr/bin/grep -iE 'nettle|hogweed|gmp' || true)
  [ -z "$out" ] || die "libgnutls.30.dylib links nettle or gmp as a library: $out (see $SRC/deps-gnutls.log)"
  out=$(sed -n 's/^Requires.private: *//p' "$DEPS/lib/pkgconfig/freetype2.pc")
  [ -z "$out" ] || die "libfreetype.6.dylib's freetype2.pc requires $out (see $SRC/deps-freetype.log)"
  echo "$deps_in" > "$DEPS/.complete"
fi

# 3b. The Vulkan loader (aoe2's DXVK), before Wine's configure, which links its Vulkan check against it
#     (SONAME_LIBVULKAN): Khronos' headers installed, then the loader built against them, into vulkan-install. The
#     shipped libvulkan.1.dylib (bundle.sh) has an @rpath ID and the SDK's libraries alone. Built again when the cmake
#     arguments change (vulkan-loader-build/.setup-inputs); fetch_vulkan_loader removes both folders.
VI="$SRC/vulkan-install"
set -- -S "$VL" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=27.0 -DCMAKE_INSTALL_PREFIX="$VI" -DVULKAN_HEADERS_INSTALL_DIR="$VI" -DBUILD_TESTS=OFF \
  -DCMAKE_C_FLAGS="-ffile-prefix-map=$SRC/=" -DCMAKE_SKIP_INSTALL_RPATH=ON
inputs=$(printf '%s\n' "$@"; echo "$VULKAN_HEADERS_COMMIT")
if [ -f "$VI/lib/libvulkan.1.dylib" ] && [ "$(cat "$SRC/vulkan-loader-build/.setup-inputs" 2> /dev/null)" = "$inputs" ]; then
  echo "wine-arm64: the Vulkan loader is up to date" >&2
else
  echo "wine-arm64: building the Vulkan loader (log: $SRC/vulkan.log)" >&2
  rm -rf "$VI" "$SRC/vulkan-loader-build" "$SRC/vulkan-headers-build"
  {
    cmake -S "$VH" -B "$SRC/vulkan-headers-build" -G Ninja -DCMAKE_INSTALL_PREFIX="$VI" \
      && cmake --install "$SRC/vulkan-headers-build" && cmake -B "$SRC/vulkan-loader-build" "$@" \
      && ninja -C "$SRC/vulkan-loader-build" && cmake --install "$SRC/vulkan-loader-build"
  } > "$SRC/vulkan.log" 2>&1 || die "building the Vulkan loader failed; see $SRC/vulkan.log"
  id=$(otool -D "$VI/lib/libvulkan.1.dylib" | tail -n +2)
  [ "$id" = @rpath/libvulkan.1.dylib ] || die "libvulkan.1.dylib's install name is ${id:-missing}, not @rpath/libvulkan.1.dylib"
  printf '%s\n' "$inputs" > "$SRC/vulkan-loader-build/.setup-inputs"
fi

# 4. Configure: out of tree, with the configure the patches carry (no autoreconf, spec §5.4: it would rewrite configure
#    with whatever autoconf is installed, and the tree would no longer be the applied one), against $DEPS alone for
#    FreeType and gnutls (--with: missing is an error). FREETYPE_LIBS links only tools/sfnt2fon, which renders the
#    bitmap fonts during the build and isn't installed: its rpath finds libfreetype's @rpath ID. Redone in a new build
#    folder (a full Wine build) when the options or the deps change: both are recorded in wine-build/.configure-inputs.
#    Both compilers (Apple clang for the unix side, llvm-mingw for the PE side) map $SRC/ away, so __FILE__ and the
#    debug info name wine/dlls/..., not the build folder (arm64 release Ruling 20); otherwise Wine's default -g -O2.
set -- --enable-archs=arm64ec,aarch64 --with-mingw=llvm-mingw --disable-tests --without-x --without-wayland \
  --without-oss --without-alsa --without-pulse --without-sane --without-usb --without-v4l2 --without-pcap \
  --without-capi --without-opencl --without-cups --with-freetype --with-gnutls --with-vulkan CC=/usr/bin/clang \
  CXX=/usr/bin/clang++ LDFLAGS="-L$VI/lib" \
  PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig" FREETYPE_CFLAGS="-I$DEPS/include/freetype2" \
  FREETYPE_LIBS="-L$DEPS/lib -lfreetype -Wl,-rpath,$DEPS/lib" GNUTLS_CFLAGS="-I$DEPS/include" \
  GNUTLS_LIBS="-L$DEPS/lib -lgnutls" CFLAGS="-g -O2 -ffile-prefix-map=$SRC/=" \
  CROSSCFLAGS="-g -O2 -ffile-prefix-map=$SRC/="
inputs=$(printf '%s\n' "$@"; cat "$DEPS/.complete")
if [ -f "$SRC/wine-build/Makefile" ] && [ "$(cat "$SRC/wine-build/.configure-inputs" 2> /dev/null)" = "$inputs" ]; then
  echo "wine-arm64: Wine's configure is up to date" >&2
else
  echo "wine-arm64: configuring (log: $SRC/configure.log)" >&2
  rm -rf "$SRC/wine-build"
  mkdir -p "$SRC/wine-build"
  ( cd "$SRC/wine-build" && unset PKG_CONFIG_PATH CPATH LIBRARY_PATH CFLAGS CXXFLAGS && "$W/configure" "$@" ) \
    > "$SRC/configure.log" 2>&1 || die "configure failed; see $SRC/configure.log"
  printf '%s\n' "$inputs" > "$SRC/wine-build/.configure-inputs"
fi
# Every build, so a configure that took Homebrew's (or /usr/local's, MacPorts') flags never gets built on:
# configure:<line>: <library> cflags: ...
[ -f "$SRC/wine-build/config.log" ] || die "no $SRC/wine-build/config.log to scan for Homebrew's flags"
out=$(LC_ALL=C /usr/bin/grep -E '(cflags|libs):.*(/opt/homebrew|/usr/local|/opt/local)' "$SRC/wine-build/config.log" \
  | sed 's/^configure:[0-9]*: //')
[ -z "$out" ] || die "Wine's configure took flags from outside the build: $(echo "$out" | tr '\n' ';')" \
  "see $SRC/wine-build/config.log"
# The libraries Wine dlopens by name: FreeType, gnutls and the Vulkan loader (ours) and libodbc (Wine's default),
# nothing found elsewhere.
out=$(sed -n 's/^#define \(SONAME_[A-Z0-9_]*\) .*/\1/p' "$SRC/wine-build/include/config.h" | sort | tr '\n' ' ')
[ "$out" = "SONAME_LIBFREETYPE SONAME_LIBGNUTLS SONAME_LIBODBC SONAME_LIBVULKAN " ] \
  || die "Wine's configure found dlopened libraries: ${out:-none}(want SONAME_LIBFREETYPE, SONAME_LIBGNUTLS," \
    "SONAME_LIBODBC, SONAME_LIBVULKAN); see $SRC/wine-build/config.log"

# 5. Make.
echo "wine-arm64: building (log: $SRC/make.log)" >&2
make -C "$SRC/wine-build" -j"$(sysctl -n hw.ncpu)" > "$SRC/make.log" 2>&1 || die "make failed; see $SRC/make.log"

# 6. FEX: the ARM64EC DLL with llvm-mingw's toolchain file (absolute path; TUNE_CPU=none, since the default reads
#    /proc/cpuinfo), the unixlib with Apple clang. Each build folder is configured again, from scratch, when its cmake
#    arguments change (<folder>/.setup-inputs, as DXMT's); fetch_fex removes both.
echo "wine-arm64: building FEX (log: $SRC/fex.log)" >&2
: > "$SRC/fex.log"
fex_setup() {  # fex_setup <what> <build folder> <cmake arguments...>
  _fs_what=$1 _fs_dir=$2; shift 2
  if [ ! -f "$_fs_dir/build.ninja" ] || [ "$(cat "$_fs_dir/.setup-inputs" 2> /dev/null)" != "$(printf '%s\n' "$@")" ]; then
    echo "wine-arm64: configuring $_fs_what" >&2
    rm -rf "$_fs_dir"
    cmake -B "$_fs_dir" "$@" >> "$SRC/fex.log" 2>&1 \
      || { rm -rf "$_fs_dir"; die "configuring $_fs_what failed; see $SRC/fex.log"; }
    printf '%s\n' "$@" > "$_fs_dir/.setup-inputs"
  fi
}
fex_setup FEX "$SRC/fex-ec" -S "$F" -G Ninja -DCMAKE_TOOLCHAIN_FILE="$F/Data/CMake/toolchain_mingw.cmake" \
  -DMINGW_TRIPLE=arm64ec-w64-mingw32 -DCMAKE_BUILD_TYPE=Release -DTUNE_CPU=none -DENABLE_LTO=False \
  -DBUILD_TESTING=False -DBUILD_FEXCONFIG=False -DENABLE_JEMALLOC_GLIBC_ALLOC=False -DENABLE_CCACHE=False
ninja -C "$SRC/fex-ec" arm64ecfex >> "$SRC/fex.log" 2>&1 || die "building libarm64ecfex.dll failed; see $SRC/fex.log"
fex_setup "FEX's unixlib" "$SRC/fex-unixlib" -S "$F/Source/Windows/UnixLib" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_COMPILER=/usr/bin/clang++ -DCMAKE_OSX_DEPLOYMENT_TARGET=27.0
ninja -C "$SRC/fex-unixlib" >> "$SRC/fex.log" 2>&1 || die "building FEX's unixlib failed; see $SRC/fex.log"
# Wine loads it only as a builtin (it ignores other DLLs in its own directories). Spec §6.3: it imports ntdll.dll alone
# and has no TLS directory (libc++ is linked statically).
dll="$SRC/fex-ec/Bin/libarm64ecfex.dll"
imports=$(llvm-objdump -p "$dll" | sed -n 's/^ *DLL Name: //p' | tr '\n' ' ')
[ "$imports" = "ntdll.dll " ] || die "libarm64ecfex.dll imports ${imports:-nothing}, not ntdll.dll alone"
if llvm-readobj --coff-tls-directory "$dll" | grep -q StartAddressOfRawData; then
  die "libarm64ecfex.dll has a TLS directory"
fi
[ "$(grep -c 'Wine builtin DLL' "$dll")" = 1 ] || die "libarm64ecfex.dll lacks Wine's builtin marker"

# 7. DXMT (arm64 DXMT spec §4): ARM64X front ends and winemetal.dll from DXMT's own cross file, linked against this
#    Wine's build tree, and an aarch64 winemetal.so against an arm64 LLVM 15 (dxmt/llvm.sh, built once). Its .metal
#    files compile through tools/xcrun-metal.sh (a second cross file names it as xcrun), so the AIR modules embedded in
#    winemetal.so name no build path. Set up again in a new build folder when the options or the wrapper change
#    (dxmt-build/.setup-inputs); fetch_dxmt removes it too. dxmt-install is redone every build.
build_llvm arm64 "$SRC/llvm-arm64" "$B/dxmt-src/llvm-project"
echo "wine-arm64: building DXMT (log: $SRC/dxmt.log)" >&2
: > "$SRC/dxmt.log"
# Rewritten only when its text changes: a newer cross file makes meson regenerate the build.
printf "[binaries]\nxcrun = ['/bin/sh', '%s']\n" "$ROOT/wine-arm64/tools/xcrun-metal.sh" > "$SRC/dxmt-xcrun.txt.new"
if cmp -s "$SRC/dxmt-xcrun.txt.new" "$SRC/dxmt-xcrun.txt"; then rm "$SRC/dxmt-xcrun.txt.new"
else mv "$SRC/dxmt-xcrun.txt.new" "$SRC/dxmt-xcrun.txt"; fi
set -- "$SRC/dxmt-build" "$D" --cross-file "$D/build-arm64ec.txt" --cross-file "$SRC/dxmt-xcrun.txt" \
  --buildtype release --strip --prefix "$SRC/dxmt-install" -Dwine_builtin_dll=false -Denable_d3d12=true \
  -Dnative_llvm_path="$SRC/llvm-arm64" -Dwine_build_path="$SRC/wine-build"
inputs=$(printf '%s\n' "$@"; cat "$SRC/dxmt-xcrun.txt" "$ROOT/wine-arm64/tools/xcrun-metal.sh")
if [ ! -f "$SRC/dxmt-build/build.ninja" ] || [ "$(cat "$SRC/dxmt-build/.setup-inputs" 2> /dev/null)" != "$inputs" ]; then
  rm -rf "$SRC/dxmt-build"
  meson setup "$@" >> "$SRC/dxmt.log" 2>&1 \
    || { rm -rf "$SRC/dxmt-build"; die "configuring DXMT failed; see $SRC/dxmt.log"; }
  printf '%s\n' "$inputs" > "$SRC/dxmt-build/.setup-inputs"
fi
meson compile -C "$SRC/dxmt-build" >> "$SRC/dxmt.log" 2>&1 || die "building DXMT failed; see $SRC/dxmt.log"
rm -rf "$SRC/dxmt-install"
meson install -C "$SRC/dxmt-build" >> "$SRC/dxmt.log" 2>&1 || die "installing DXMT failed; see $SRC/dxmt.log"
# The bundle's DXMT/version (spec §6): the pin and the series, or +dev for a tree with work of its own.
if [ "$dxmt_mode" = development ]; then
  echo "$DXMT_COMMIT+dev" > "$SRC/dxmt-install/version"
else
  printf '%s+%.12s\n' "$DXMT_COMMIT" "$dxmt_series" > "$SRC/dxmt-install/version"
fi
# The DXIL host tools, arm64, next to wine.app (not in it).
mkdir -p "$OUT"
build_probe arm64 "$SRC/llvm-arm64" "$OUT" "$SRC"
build_translate arm64 "$SRC/llvm-arm64" "$D" "$SRC/dxmt-build" "$OUT" "$SRC"
# The MetalFX presenter (arm64 release spec §5.3), which winemetal.so loads from beside itself (DXMT patch 0002).
mkdir -p "$SRC/presenter"
/usr/bin/clang -arch arm64 -mmacosx-version-min=27.0 -fobjc-arc -O2 -dynamiclib \
  -install_name @rpath/libmacneutron-present.dylib -framework Foundation -framework AppKit -framework QuartzCore \
  -framework Metal -framework MetalFX -o "$SRC/presenter/libmacneutron-present.dylib" "$ROOT/presenter/present.m" \
  > "$SRC/presenter.log" 2>&1 || die "building the presenter failed; see $SRC/presenter.log"

# 7b. KosmicKrisp (aoe2's DXVK runs on it): two meson builds of the patched Mesa tree, as shadexternals' recipe does. First
#     Mesa's build-time compilers (mesa_clc, vtn_bindgen2, kk_clc) against Homebrew's LLVM, then the driver,
#     libvulkan_kosmickrisp.dylib, with those compilers on PATH, static where it can be, and against no LLVM and no
#     pkg-config library (only the SDK's). Mesa's generators import Mako, PyYAML and packaging: a virtual environment of
#     the pinned versions (mesa-venv/.modules), first on PATH for meson's python3. Each build folder is set up again when
#     its options change (<folder>/.setup-inputs); fetch_mesa removes both.
echo "wine-arm64: building KosmicKrisp (log: $SRC/mesa.log)" >&2
: > "$SRC/mesa.log"
MV="$SRC/mesa-venv"
if [ "$(cat "$MV/.modules" 2> /dev/null)" != "$MESA_PYTHON_MODULES" ]; then
  rm -rf "$MV"
  # shellcheck disable=SC2086  # a list of modules
  { python3 -m venv "$MV" && "$MV/bin/pip" install -q $MESA_PYTHON_MODULES; } >> "$SRC/mesa.log" 2>&1 \
    || die "can't set up Mesa's Python environment; see $SRC/mesa.log"
  echo "$MESA_PYTHON_MODULES" > "$MV/.modules"
fi
mesa_common="-Dplatforms=macos -Dvulkan-drivers=kosmickrisp -Dgallium-drivers= -Dopengl=false -Dzstd=disabled"
# Apple's compilers by name: llvm-mingw's clang, first on PATH, targets Windows.
mesa_cc="CC=/usr/bin/clang CXX=/usr/bin/clang++ OBJC=/usr/bin/clang OBJCXX=/usr/bin/clang++"
mesa_setup() {  # mesa_setup <what> <build folder> <PATH> <environment...> -- <meson options...>; PATH isn't an input
  _ms_what=$1 _ms_dir=$2 _ms_path=$3; shift 3
  _ms_inputs=$(printf '%s\n' "$@"; cat "$MV/.modules")
  if [ -f "$_ms_dir/build.ninja" ] && [ "$(cat "$_ms_dir/.setup-inputs" 2> /dev/null)" = "$_ms_inputs" ]; then return 0; fi
  echo "wine-arm64: configuring $_ms_what" >&2
  rm -rf "$_ms_dir"
  _ms_env=
  while [ "$1" != -- ]; do _ms_env="$_ms_env $1"; shift; done
  shift
  # shellcheck disable=SC2086  # the environment is a list
  env PATH="$_ms_path" $_ms_env meson setup "$_ms_dir" "$M" "$@" >> "$SRC/mesa.log" 2>&1 \
    || { rm -rf "$_ms_dir"; die "configuring $_ms_what failed; see $SRC/mesa.log"; }
  printf '%s\n' "$_ms_inputs" > "$_ms_dir/.setup-inputs"
}
MT="$SRC/mesa-tools" MB="$SRC/mesa-build"
# shellcheck disable=SC2086  # mesa_cc and mesa_common are lists
mesa_setup "Mesa's compilers" "$MT" "$MV/bin:$PATH" $mesa_cc LLVM_CONFIG="$LLVM_CONFIG" PKG_CONFIG_PATH="$SPIRV_PC" -- \
  --buildtype=release \
  -Dinstall-mesa-clc=true -Dinstall-precomp-compiler=true $mesa_common
env PATH="$MV/bin:$PATH" meson compile -C "$MT" mesa_clc vtn_bindgen2 kk_clc >> "$SRC/mesa.log" 2>&1 \
  || die "building Mesa's compilers failed; see $SRC/mesa.log"
mesa_path="$MT/src/compiler/clc:$MT/src/compiler/spirv:$MT/src/kosmickrisp/clc:$MV/bin:$PATH"
# shellcheck disable=SC2086
mesa_setup KosmicKrisp "$MB" "$mesa_path" $mesa_cc PKG_CONFIG_LIBDIR=/nonexistent -- --buildtype=release --prefer-static \
  -Dmesa-clc=system -Dprecomp-compiler=system -Dspirv-tools=disabled -Dllvm=disabled $mesa_common \
  -Dc_args="-ffile-prefix-map=$SRC/=" -Dcpp_args="-ffile-prefix-map=$SRC/=" -Dobjc_args="-ffile-prefix-map=$SRC/="
env PATH="$mesa_path" meson compile -C "$MB" vulkan_kosmickrisp kosmickrisp_mesa_icd >> "$SRC/mesa.log" 2>&1 \
  || die "building KosmicKrisp failed; see $SRC/mesa.log"
kk="$MB/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.dylib"
[ -f "$kk" ] && [ -f "$MB/src/kosmickrisp/vulkan/kosmickrisp_mesa_icd.aarch64.json" ] \
  || die "KosmicKrisp's build left no driver or manifest in $MB/src/kosmickrisp/vulkan; see $SRC/mesa.log"
id=$(otool -D "$kk" | tail -n +2)
[ "$id" = @rpath/libvulkan_kosmickrisp.dylib ] || install_name_tool -id @rpath/libvulkan_kosmickrisp.dylib "$kk" \
  || die "can't set libvulkan_kosmickrisp.dylib's install name"

# 7c. DXVK (aoe2's renderer) as ARM64EC, with llvm-mingw's arm64ec compilers (a cross file written here, which maps $SRC/
#     away), into dxvk-install: d3d10core.dll, d3d11.dll and dxgi.dll go into the bundle's DXVK/. Set up again in a new
#     build folder when the options change (dxvk-build/.setup-inputs); fetch_dxvk removes it.
echo "wine-arm64: building DXVK (log: $SRC/dxvk.log)" >&2
: > "$SRC/dxvk.log"
T="$(sh "$ROOT/dxmt/toolchain.sh")"
cat > "$SRC/dxvk-arm64ec.txt.new" << EOF2
[binaries]
c = '$T/arm64ec-w64-mingw32-clang'
cpp = '$T/arm64ec-w64-mingw32-clang++'
ar = '$T/arm64ec-w64-mingw32-ar'
strip = '$T/arm64ec-w64-mingw32-strip'
windres = '$T/arm64ec-w64-mingw32-windres'

[built-in options]
c_args = ['-ffile-prefix-map=$SRC/=']
cpp_args = ['-ffile-prefix-map=$SRC/=']

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'windows'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF2
# Rewritten only when its text changes: a newer cross file makes meson regenerate the build.
if cmp -s "$SRC/dxvk-arm64ec.txt.new" "$SRC/dxvk-arm64ec.txt"; then rm "$SRC/dxvk-arm64ec.txt.new"
else mv "$SRC/dxvk-arm64ec.txt.new" "$SRC/dxvk-arm64ec.txt"; fi
set -- "$SRC/dxvk-build" "$X" --cross-file "$SRC/dxvk-arm64ec.txt" --buildtype release --strip -Dbuild_id=false \
  --prefix "$SRC/dxvk-install" --bindir aarch64-windows --libdir aarch64-windows
inputs=$(printf '%s\n' "$@"; cat "$SRC/dxvk-arm64ec.txt")
if [ ! -f "$SRC/dxvk-build/build.ninja" ] || [ "$(cat "$SRC/dxvk-build/.setup-inputs" 2> /dev/null)" != "$inputs" ]; then
  rm -rf "$SRC/dxvk-build"
  meson setup "$@" >> "$SRC/dxvk.log" 2>&1 || { rm -rf "$SRC/dxvk-build"; die "configuring DXVK failed; see $SRC/dxvk.log"; }
  printf '%s\n' "$inputs" > "$SRC/dxvk-build/.setup-inputs"
fi
meson compile -C "$SRC/dxvk-build" >> "$SRC/dxvk.log" 2>&1 || die "building DXVK failed; see $SRC/dxvk.log"
rm -rf "$SRC/dxvk-install"
meson install -C "$SRC/dxvk-build" >> "$SRC/dxvk.log" 2>&1 || die "installing DXVK failed; see $SRC/dxvk.log"
# The bundle's DXVK/version: the pin, or +dev for a tree with work of its own.
if [ "$dxvk_mode" = development ]; then echo "$DXVK_COMMIT+dev" > "$SRC/dxvk-install/version"
else echo "$DXVK_COMMIT" > "$SRC/dxvk-install/version"; fi

# 8. Bundle and sign (make install into wine.app, the loader's entitlements, every check on the result). First the
#    bundle's licenses/SOURCE (ship-base spec §4): the inputs it is built from, each tree's series or dev.
write_source "$SRC/SOURCE" "$mac"
echo "wine-arm64: bundling (log: $OUT/install.log)" >&2
sh "$ROOT/wine-arm64/bundle.sh"

# 9. Stamp, last: only a finished build of the applied patches gets one.
if [ -z "$dev" ]; then
  echo "$stamp" > "$OUT/version"
fi
echo "wine-arm64: built $OUT/wine.app" >&2
