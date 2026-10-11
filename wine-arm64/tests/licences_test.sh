#!/bin/sh
# licences_test.sh [--self-test] <wine.app>: every notice the shipped binaries need is in the bundle (ship-base spec §4).
# Prints MISSING <what> per gap, then PASS or FAIL. Read-only. BUILD_DIR replaces build/ (FEX's External list).
# --app <MacNeutron.app> (arm64 release spec §7.1, gate R4): the app's own licences (MIT, llvm-mingw's for steam.exe,
# equal to wine.app's copies, a README pointing into wine.app), then the check above on its Contents/Helpers/wine.app.
# --self-test proves it red on copies in $TMPDIR: a licence file deleted (FEX's, MacNeutron's), an extra FEX external.
# ponytail: a flat path list, no manifest format; add one when a second bundle needs the same list.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
g() { LC_ALL=C /usr/bin/grep "$@"; }

check() {  # check <wine.app> <build dir>
  R="$1/Contents/Resources"
  L="$R/licenses"
  bad=0
  miss() { echo "MISSING $*"; bad=1; }
  key() { g -q "^$1=" "$L/SOURCE" 2> /dev/null || miss "SOURCE line $1="; }
  has() { ls "$R"/lib/wine/aarch64-unix/$1 > /dev/null 2>&1; }  # unquoted: $1 is a glob

  # 1. Files copied verbatim from the source trees (bundle.sh's put list).
  for f in \
    DXMT/COPYING.LIB DXMT/LICENSE DXMT/LICENSE.OLD \
    licenses/README licenses/SOURCE licenses/NOTICES.md \
    licenses/wine/LICENSE licenses/wine/COPYING.LIB licenses/wine/AUTHORS licenses/wine/NOTICES.md \
    licenses/wine/gsm-COPYRIGHT licenses/wine/faudio-LICENSE \
    licenses/fex/LICENSE \
    licenses/fex/fmt-LICENSE licenses/fex/xxhash-LICENSE licenses/fex/tiny-json-LICENSE \
    licenses/fex/cpp-optparse-LICENSE licenses/fex/unordered_dense-LICENSE licenses/fex/rpmalloc-LICENSE \
    licenses/fex/range-v3-LICENSE.txt licenses/fex/cephes-LICENSE \
    licenses/llvm/LICENSE.TXT licenses/llvm/COPYRIGHT.regex \
    licenses/llvm-mingw/LICENSE.TXT licenses/llvm-mingw/COPYING.MinGW-w64-runtime.txt \
    licenses/macneutron/LICENSE
  do [ -s "$R/$f" ] || miss "$f"; done

  # 2. Notices that live only in source headers: the committed NOTICES.md names each holder.
  for h in "Regents of the University of California" "VIXL authors" "Rich Felker" "Arm Limited" "Will Faust" \
           "Microsoft Corporation" "Alexander Bessonov" "Unicode, Inc." "Henry Spencer" "Zebediah Figura" \
           "Marc-Aurel Zent"
  do g -qF "$h" "$L/NOTICES.md" 2> /dev/null || miss "NOTICES.md entry for $h"; done
  g -qF 'macneutron/LICENSE' "$L/README" 2> /dev/null || miss "MacNeutron entry (macneutron/LICENSE) in README"

  # 3. Drift: every FEX external the build compiled has a licence above (vixl, zydis, tracy... must stay out).
  for d in "$2"/wine-arm64-src/fex-ec/External/*/; do
    [ -d "$d" ] || { miss "FEX's External folder in $2/wine-arm64-src/fex-ec"; continue; }
    case $(basename "$d") in SoftFloat-3e|cephes|fmt|range-v3|rpmalloc|tiny-json|unordered_dense|xxhash) ;;
      *) miss "a licence decision for FEX External/$(basename "$d")" ;; esac
  done

  # 4. Sub-project 3's libraries, once they are in the bundle (a library present without its licence is a failure).
  #    nettle and gmp are folded into libgnutls: their texts come with it.
  if has 'libfreetype*'; then
    for f in LICENSE.TXT FTL.TXT bdf-README pcf-README; do [ -s "$L/freetype/$f" ] || miss "freetype/$f"; done
    g -qF "The FreeType Project" "$L/README" 2> /dev/null || miss "FreeType credit line in README"
    g -qF "Zappa Nardelli" "$L/NOTICES.md" 2> /dev/null || miss "NOTICES.md entry for FreeType's ft_hash"
  fi
  if has 'libgnutls*'; then
    for f in gnutls/COPYING.LESSERv2 gnutls/COPYING.LESSERv3 gnutls/COPYINGv3 nettle/COPYING.LESSERv3 nettle/COPYINGv3 \
             gmp/COPYING.LESSERv3 gmp/COPYINGv3 gnutls/cryptogams-license.txt gnutls/inih-LICENSE.txt
    do [ -s "$L/$f" ] || miss "$f"; done
    g -qF "Markus Friedl" "$L/NOTICES.md" 2> /dev/null || miss "NOTICES.md entry for Markus Friedl"
  fi
  if has 'libfreetype*' || has 'libgnutls*'; then
    for n in FREETYPE GNUTLS NETTLE GMP; do key "${n}_URL"; key "${n}_SHA256"; done
  fi
  if has lsteamclient.so; then
    for f in LICENSE NOTE; do [ -s "$L/lsteamclient/$f" ] || miss "lsteamclient/$f"; done
    key LSTEAMCLIENT_COMMIT; key LSTEAMCLIENT_SERIES
    g -qF "maintainer's decision of 2026-10-04" "$L/README" 2> /dev/null \
      || miss "lsteamclient entry in README with the maintainer's decision of 2026-10-04"
  fi

  # 4b. The Vulkan stack (aoe2's DXVK), once it is in the bundle.
  if has libvulkan_kosmickrisp.dylib; then
    for f in mesa/license.rst mesa/MIT mesa/Apache-2.0 mesa/BSL-1.0 mesa/SGI-B-2.0 vulkan-loader/LICENSE.txt \
             vulkan-headers/LICENSE.md vulkan-headers/Apache-2.0.txt vulkan-headers/MIT.txt
    do [ -s "$L/$f" ] || miss "$f"; done
    for h in "Yann Collet" "Berkeley SoftFloat"; do g -qF "$h" "$L/NOTICES.md" 2> /dev/null || miss "NOTICES.md entry for $h"; done
    g -qF "KosmicKrisp (libvulkan_kosmickrisp.dylib" "$L/README" 2> /dev/null || miss "KosmicKrisp entry in README"
    g -qF "The Vulkan loader (libvulkan.1.dylib" "$L/README" 2> /dev/null || miss "Vulkan loader entry in README"
    for k in VULKAN_HEADERS_COMMIT VULKAN_LOADER_COMMIT MESA_COMMIT MESA_SERIES; do key "$k"; done
  fi
  if [ -d "$R/DXVK" ]; then
    for f in LICENSE dxbc-spirv-LICENSE libdisplay-info-LICENSE directx-COPYING.MinGW-w64.txt spirv-headers-LICENSE \
             vulkan-headers-LICENSE.md
    do [ -s "$L/dxvk/$f" ] || miss "dxvk/$f"; done
    g -qF "DXVK 3.1.1 (the Direct3D to Vulkan DLLs" "$L/README" 2> /dev/null || miss "DXVK entry in README"
    for k in DXVK_COMMIT DXVK_SERIES DXVK_SUBMODULE_dxbc-spirv DXVK_SUBMODULE_libdisplay-info; do key "$k"; done
  fi

  # 5. Source correspondence: SOURCE names the exact inputs.
  for k in MACNEUTRON_COMMIT WINE_COMMIT WINE_SERIES FEX_COMMIT FEX_SERIES FEX_SUBMODULE_fmt FEX_SUBMODULE_range-v3 \
           FEX_SUBMODULE_rpmalloc FEX_SUBMODULE_unordered_dense FEX_SUBMODULE_xxhash FEX_SUBMODULE_cpp-optparse \
           DXMT_COMMIT DXMT_SERIES DXMT_SUBMODULE_nvapi DXMT_SUBMODULE_directx LLVM_TAG LLVM_MINGW_SHA256
  do key "$k"; done

  if [ $bad = 0 ]; then echo "PASS licences_test"; else echo "FAIL licences_test"; return 1; fi
}

B="${BUILD_DIR:-$ROOT/build}"
if [ "${1:-}" = --app ]; then
  A="${2:?usage: licences_test.sh --app <MacNeutron.app>}"
  AL="$A/Contents/Resources/licenses"
  abad=0
  for f in LICENSE LICENSE.TXT COPYING.MinGW-w64-runtime.txt README; do
    [ -s "$AL/$f" ] || { echo "MISSING Contents/Resources/licenses/$f"; abad=1; }
  done
  g -qF 'Contents/Helpers/wine.app/Contents/Resources/licenses/' "$AL/README" 2> /dev/null \
    || { echo "MISSING the README's pointer to Contents/Helpers/wine.app/Contents/Resources/licenses/"; abad=1; }
  for f in LICENSE.TXT COPYING.MinGW-w64-runtime.txt; do  # steam.exe's: the same texts as wine.app's llvm-mingw/
    cmp -s "$AL/$f" "$A/Contents/Helpers/wine.app/Contents/Resources/licenses/llvm-mingw/$f" \
      || { echo "DIFFERENT Contents/Resources/licenses/$f from wine.app's licenses/llvm-mingw/$f"; abad=1; }
  done
  check "$A/Contents/Helpers/wine.app" "$B" || abad=1
  if [ $abad = 0 ]; then echo "PASS licences_test --app"; else echo "FAIL licences_test --app"; exit 1; fi
  exit 0
fi
if [ "${1:-}" != --self-test ]; then
  check "${1:?usage: licences_test.sh [--self-test] <wine.app> | --app <MacNeutron.app>}" "$B"
  exit
fi

APP="${2:?usage: licences_test.sh --self-test <wine.app>}"
T="$(mktemp -d "${TMPDIR:-/tmp}/licences_test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL licences_test self-test: $*"; exit 1; }
# red <what> <MISSING line>: the copies fail, naming the gap.
red() {
  out=$(check "$T/wine.app" "$T/b") && fail "$1 still passes"
  case "$out" in *"MISSING $2"*) ;; *) fail "$1 does not say MISSING $2: $out" ;; esac
}
cp -cR "$APP" "$T/wine.app" || fail "can't copy $APP"
mkdir -p "$T/b/wine-arm64-src/fex-ec"
cp -cR "$B/wine-arm64-src/fex-ec/External" "$T/b/wine-arm64-src/fex-ec/" || fail "can't copy FEX's External folder"
out=$(check "$T/wine.app" "$T/b") || fail "the unchanged copies fail: $out"
rm "$T/wine.app/Contents/Resources/licenses/fex/xxhash-LICENSE"
red "a copy without fex/xxhash-LICENSE" licenses/fex/xxhash-LICENSE
cp -c "$APP/Contents/Resources/licenses/fex/xxhash-LICENSE" "$T/wine.app/Contents/Resources/licenses/fex/"
rm "$T/wine.app/Contents/Resources/licenses/macneutron/LICENSE"
red "a copy without macneutron/LICENSE" licenses/macneutron/LICENSE
cp -c "$APP/Contents/Resources/licenses/macneutron/LICENSE" "$T/wine.app/Contents/Resources/licenses/macneutron/"
mkdir "$T/b/wine-arm64-src/fex-ec/External/vixl"
red "an extra External/vixl" "a licence decision for FEX External/vixl"
echo "PASS licences_test self-test"
