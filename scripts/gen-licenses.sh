#!/usr/bin/env bash
# gen-licenses.sh — (re)assemble licenses/ from the pinned vendored sources (D-113).
#
#   scripts/gen-licenses.sh            # rewrite licenses/ from vendor/
#   scripts/gen-licenses.sh --check    # fail if licenses/ differs from what vendor/ says
#
# licenses/ is COMMITTED (the public tree must carry it without a vendor
# checkout) and is staged into every app bundle by stage-bundle-content.sh.
# Every text here is copied verbatim from the component's own source at the
# pinned version — nothing is paraphrased. Run after any pin or dependency bump
# and commit the result; --check is what a reviewer runs to prove it is current.
#
# Two texts are not in any vendored tree and are kept as committed files rather
# than fetched at build time: MoltenVK's LICENSE (we vendor only its prebuilt
# static xcframework) and cereal's LICENSE (header-only code compiled INTO the
# static MoltenVK library; its symbols are in libMoltenVK.a). Their provenance
# is recorded in licenses/README.md. SPIRV-Cross, also compiled into MoltenVK,
# is Apache-2.0 — the same text as licenses/MoltenVK/LICENSE.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
V="$ROOT/vendor"
OUT="$ROOT/licenses"

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

for d in "$V/openQ4" "$V/openQ4-game" "$V/SDL" "$V/openal-soft"; do
	[ -d "$d" ] || { echo "FATAL: $d missing — run scripts/fetch-vendor.sh and scripts/build-ios-deps.sh first" >&2; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
T="$WORK/licenses"
mkdir -p "$T"

cpv() { # <src> <dest-relative-to-licenses>
	[ -s "$1" ] || { echo "FATAL: licence source missing or empty: $1" >&2; exit 1; }
	mkdir -p "$(dirname "$T/$2")"
	cp "$1" "$T/$2"
}
# Copy lines <from>..<to> of a source file, asserting the range starts at the
# expected text so a moved licence block fails loudly instead of quietly
# copying the wrong lines.
excerpt() { # <src> <from> <to> <expected-first-line-substring> <dest>
	local first
	first="$(sed -n "${2}p" "$1")"
	case "$first" in
		*"$4"*) ;;
		*) echo "FATAL: $1 line $2 is '$first', expected it to contain '$4' — licence block moved" >&2; exit 1 ;;
	esac
	mkdir -p "$(dirname "$T/$5")"
	sed -n "${2},${3}p" "$1" > "$T/$5"
}

# --- openQ4 engine (GPLv3; the repo's own LICENSE is the same text) ----------
cpv "$V/openQ4/LICENSE"                                   openQ4/LICENSE
cpv "$V/openQ4/LICENSES/DOOM-3-ADDITIONAL-TERMS.txt"      openQ4/DOOM-3-ADDITIONAL-TERMS.txt
cpv "$V/openQ4/LICENSES/DOOM-3-BFG-ADDITIONAL-TERMS.txt"  openQ4/DOOM-3-BFG-ADDITIONAL-TERMS.txt

# --- openQ4-game (Quake 4 SDK EULA, NOT the GPL) ------------------------------
cpv "$V/openQ4-game/LICENSE"                              openQ4-game/LICENSE
cpv "$V/openQ4-game/EULA.Development Kit.rtf"             "openQ4-game/EULA.Development Kit.rtf"

# --- SDL3 (zlib) -----------------------------------------------------------------
cpv "$V/SDL/LICENSE.txt"                                  SDL3/LICENSE.txt

# --- OpenAL Soft (LGPL-2.1, plus its bundled pieces) — upstream's macOS app
#     ships exactly this set (tools/build/package_nightly.py) ---------------------
cpv "$V/openal-soft/COPYING"                              openal-soft/COPYING
cpv "$V/openal-soft/LICENSE-pffft"                        openal-soft/LICENSE-pffft
cpv "$V/openal-soft/BSD-3Clause"                          openal-soft/BSD-3Clause
cpv "$V/openal-soft/fmt-11.2.0/LICENSE"                   openal-soft/LICENSE-fmt
cpv "$V/openal-soft/gsl/LICENSE"                          openal-soft/LICENSE-gsl
OPENAL_TAG="$(git -C "$V/openal-soft" describe --tags --exact-match 2>/dev/null || true)"
[ -n "$OPENAL_TAG" ] || { echo "FATAL: vendor/openal-soft is not at a release tag" >&2; exit 1; }
cat > "$T/openal-soft/SOURCE.md" <<EOF
# OpenAL Soft — corresponding source

This app statically links OpenAL Soft ${OPENAL_TAG}, licensed under the GNU
Library General Public License version 2 (see COPYING), built unmodified from:

    https://github.com/kcat/openal-soft  tag ${OPENAL_TAG}

The exact build recipe is \`scripts/build-ios-deps.sh\` in this app's source
repository, which is published under the GPLv3 with every object file the app
is linked from reproducible from it.
EOF

# --- Header-only / single-file components compiled into the engine ------------
excerpt "$V/openQ4/src/external/volk/volk.h" \
	"$(grep -n 'Copyright (c) 2018-' "$V/openQ4/src/external/volk/volk.h" | tail -1 | cut -d: -f1)" \
	"$(awk '/Copyright \(c\) 2018-/{f=NR} f && /SOFTWARE\./{print NR; exit}' "$V/openQ4/src/external/volk/volk.h")" \
	"Copyright (c) 2018-" volk/LICENSE
excerpt "$V/openQ4/src/external/vma/vk_mem_alloc.h" 2 \
	"$(awk 'NR>2 && /^\/\/ THE SOFTWARE\.|^\/\/ SOFTWARE\./{print NR; exit}' "$V/openQ4/src/external/vma/vk_mem_alloc.h")" \
	"Copyright (c) 2017-" VulkanMemoryAllocator/LICENSE
excerpt "$V/openQ4/subprojects/stb_vorbis/stb_vorbis.c" \
	"$(grep -n 'This software is available under 2 licenses' "$V/openQ4/subprojects/stb_vorbis/stb_vorbis.c" | cut -d: -f1)" \
	"$(awk '/ALTERNATIVE B - Public Domain/{f=1} f && /WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE\./{print NR; exit}' "$V/openQ4/subprojects/stb_vorbis/stb_vorbis.c")" \
	"This software is available under 2 licenses" stb_vorbis/LICENSE
excerpt "$V/openQ4/subprojects/glew/src/glew.c" 1 \
	"$(awk '/THE POSSIBILITY OF SUCH DAMAGE\./{print NR+1; exit}' "$V/openQ4/subprojects/glew/src/glew.c")" \
	"/*" GLEW/LICENSE
excerpt "$V/openQ4/src/external/vulkan/include/vulkan/vulkan_core.h" 4 8 \
	"/*" Vulkan-Headers/NOTICE

# --- Committed, provenance-recorded texts (see header) ------------------------
for f in MoltenVK/LICENSE cereal/LICENSE README.md; do
	[ -s "$OUT/$f" ] || { echo "FATAL: committed licence text $OUT/$f is missing" >&2; exit 1; }
	mkdir -p "$(dirname "$T/$f")"
	cp "$OUT/$f" "$T/$f"
done

if [ "$CHECK" = 1 ]; then
	if diff -r "$T" "$OUT" > "$WORK/diff" 2>&1; then
		echo "LICENSES OK — licenses/ matches the pinned vendored sources"
		exit 0
	fi
	echo "FATAL: licenses/ is stale against vendor/:" >&2
	head -40 "$WORK/diff" >&2
	exit 1
fi

rm -rf "$OUT.new"
cp -R "$T" "$OUT.new"
rm -rf "$OUT"
mv "$OUT.new" "$OUT"
echo "LICENSES written: $(find "$OUT" -type f | wc -l | tr -d ' ') files in licenses/"
