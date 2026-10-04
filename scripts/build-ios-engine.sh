#!/usr/bin/env bash
# build-ios-engine.sh — compile openQ4 (engine + Vulkan renderer) into a static
# library for iOS, from the overlay tree.
#
#   build/src-ios  (scripts/sync-overlay.sh)  ->  build/ios/libopenq4.a
#
# The Vulkan renderer is compiled INTO the same archive rather than built as a
# loadable module: iOS has no dlopen'able unsigned code, so upstream's
# renderer-module split has to collapse to a static link here. The module's
# sources are otherwise unchanged.
#
# Source lists come from upstream's own manifest (tools/build/meson_sources.py),
# never hand-maintained, so a pin bump cannot silently drop or add files.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TREE="$ROOT/build/src-ios"
GEN="$ROOT/build/ios-gen"
IOS_MIN=16.0
# 2.5, not 2.0: the prebuilt MoltenVK xrOS slices are stamped minos 2.5 (D-090).
XROS_MIN=2.5

# Lane: "device" (iphoneos), "sim" (iphonesimulator), "visionos" (xros) or
# "visionos-sim" (xrsimulator). Must match the lane build-ios-deps.sh was run
# with — the archives are not interchangeable.
LANE="${1:-device}"
case "$LANE" in
	device)       SDKNAME=iphoneos        ; DEPS="$ROOT/build/ios-deps"          ; OUT="$ROOT/build/ios" ;;
	sim)          SDKNAME=iphonesimulator ; DEPS="$ROOT/build/ios-sim-deps"      ; OUT="$ROOT/build/ios-sim" ;;
	visionos)     SDKNAME=xros            ; DEPS="$ROOT/build/visionos-deps"     ; OUT="$ROOT/build/visionos" ;;
	visionos-sim) SDKNAME=xrsimulator     ; DEPS="$ROOT/build/visionos-sim-deps" ; OUT="$ROOT/build/visionos-sim" ;;
	*) echo "usage: $0 [device|sim|visionos|visionos-sim]" >&2; exit 1 ;;
esac
JOBS="$(sysctl -n hw.ncpu)"

[ -d "$TREE/src" ] || { echo "FATAL: run scripts/sync-overlay.sh first" >&2; exit 1; }
[ -f "$DEPS/sdl-prefix/lib/libSDL3.a" ] || { echo "FATAL: run scripts/build-ios-deps.sh first" >&2; exit 1; }

SDK="$(xcrun --sdk "$SDKNAME" --show-sdk-path)"
CXX="$(xcrun --sdk "$SDKNAME" -f clang++)"
LIBTOOL="$(xcrun --sdk "$SDKNAME" -f libtool)"

mkdir -p "$OUT/obj" "$OUT/logs"

DEFS=(
  -DUSE_OPENAL -DGLEW_NO_GLU -DID_GL_HARDLINK -DMACOS_X=1
  -DUSE_OPENAL_SOFT_INCLUDES=1 -DUSE_SDL3=1 -D__DOOM_DLL__
  -DOPENQ4_IOS=1
)
# visionOS is an Apple mobile lane: it keeps OPENQ4_IOS (shared touch/lifecycle/
# filesystem shape) and ADDS its own flag rather than replacing it (D-089). In
# engine source the SDK macro TARGET_OS_VISION is tested BEFORE TARGET_OS_IPHONE
# — visionOS sets both (D-069, patch 0022).
#
# OPENQ4_SWIFT_MAIN: the visionOS app entry is a SwiftUI @main, required to
# declare the Phase 6 ImmersiveSpace, so SDL's UIApplicationMain wrapper is
# bypassed. It renames the engine entry point to openq4_engine_main() and drops
# <SDL3/SDL_main.h>; the shell calls SDL_SetMainReady() then this function.
# vkQuake D-028 is why the choice is made now and not later: switching entry
# style over a bundle id that has already run restores a persisted scene
# session naming SDL's scene delegate and crashes at PC=0.
case "$LANE" in
# OPENQ4_VISIONOS_3D: the Phase 6 stereo path (overlay 0019's stereo block,
# ios/shell-visionos/OpenQ4Immersive.m). visionOS lanes ONLY — the iOS target
# must preprocess to exactly the code it had before (D-100).
	visionos|visionos-sim) DEFS+=( -DOPENQ4_VISIONOS=1 -DOPENQ4_SWIFT_MAIN=1 -DOPENQ4_VISIONOS_3D=1 ) ;;
esac
# The iOS client owns no renderer of its own: there is no GL to statically link,
# and the Vulkan renderer supplies the backend. That is exactly upstream's
# "module-only client" shape (meson.build:1105), which drops the built-in GL
# renderer path and leaves renderSystem/renderModelManager as globals the
# renderer publishes at boot. Without it the platform backend also compiles in
# gl_ContextSDL3.cpp, whose GLimp_* collide with the Vulkan module's stubs.
ENGINE_DEFS=( -DOPENQ4_RENDERER_MODULE_ONLY -DOPENQ4_RENDERER_MODULE_STATIC )
# VK_ENABLE_BETA_EXTENSIONS is mandatory on Apple targets: without it the Vulkan
# headers compile out VK_KHR_portability_subset, which is exactly what MoltenVK
# requires. OPENQ4_RENDERER_VK_MODULE keeps the renderer sources on their module
# code paths (see D-012).
RENDERER_DEFS=(
  -DOPENQ4_RENDERER_MODULE
  -DOPENQ4_RENDERER_VK_MODULE
  -DOPENQ4_RENDERER_MODULE_STATIC
  '-DOPENQ4_RENDERER_BACKEND_NAME="vulkan"'
  '-DOPENQ4_RENDERER_BACKEND_DESC="openQ4 native Vulkan renderer module"'
  -DVMA_STATIC_VULKAN_FUNCTIONS=0
  -DVMA_DYNAMIC_VULKAN_FUNCTIONS=1
  -DVK_ENABLE_BETA_EXTENSIONS
)

INCS=(
  # FIRST: the iOS volk shim shadows src/external/volk/volk.h (D-013). All nine
  # `#include "volk.h"` sites use the quoted form and none live inside volk's
  # own directory, so include-order shadowing needs no upstream edit.
  -I"$ROOT/ios/compat"
  -I"$ROOT/ios/shell"                        # console bridge header
  -I"$GEN"                                   # openq4_version_generated.h
  -I"$TREE/src"
  -I"$TREE/.tmp/gamelibs_stage/src/game"
  -I"$TREE/subprojects/glew/include"
  -I"$TREE/subprojects/stb_vorbis"
  -I"$TREE/src/external/vulkan/include"
  -I"$TREE/src/external/volk"
  -I"$TREE/src/external/vma"
  -I"$DEPS/sdl-prefix/include"
  -I"$DEPS/openal-prefix/include"
  -I"$DEPS/openal-prefix/include/AL"
)
case "$LANE" in
	device)       TARGET_FLAGS=( -arch arm64 -miphoneos-version-min="$IOS_MIN" ) ;;
	sim)          TARGET_FLAGS=( -target "arm64-apple-ios${IOS_MIN}-simulator" ) ;;
	visionos)     TARGET_FLAGS=( -target "arm64-apple-xros${XROS_MIN}" ) ;;
	visionos-sim) TARGET_FLAGS=( -target "arm64-apple-xros${XROS_MIN}-simulator" ) ;;
esac

CC="$(xcrun --sdk "$SDKNAME" -f clang)"
CFLAGS=(
  -isysroot "$SDK" "${TARGET_FLAGS[@]}"
  -O2 -DNDEBUG -fno-strict-aliasing -Wno-everything
)

CXXFLAGS=(
  -isysroot "$SDK" "${TARGET_FLAGS[@]}"
  -std=c++20 -O2 -DNDEBUG -fno-strict-aliasing -fno-omit-frame-pointer
  -Wno-everything
  -include "$TREE/src/idlib/precompiled.h"   # every TU assumes idlib's PCH
)

collect() {
	( cd "$TREE" && python3 tools/build/meson_sources.py \
		--host-system darwin --platform-backend sdl3 --target-kind client \
		--emit "$1" --renderer module --include-game false )
}

# openQ4 splits the client across several meson targets. All of them must be in
# the archive: imagetools supplies R_LoadImage / R_WriteTGA (used by the session,
# renderer and font code), render_geo the geometry hooks. Compiling only "engine"
# links but leaves those undefined.
# BSE (Raven's effects system, reimplemented in-tree) is compiled INTO the
# client — upstream discovers its sources with list_sources.py rather than
# listing them in meson_sources.py, so we drive the same tool.
BSE_SRC="$( cd "$TREE" && python3 tools/build/list_sources.py "$TREE" src/bse )"

ENGINE_SRC="$(collect engine)
$(collect imagetools)
$(collect render_geo)
$BSE_SRC"
RENDER_SRC="$(collect renderer_vk)"
n_engine=$(echo "$ENGINE_SRC" | grep -c . || true)
n_render=$(echo "$RENDER_SRC" | grep -c . || true)
# The compiled-in version banner is refreshed here rather than only by
# sync-overlay.sh, because an engine rebuilt without a re-sync would otherwise
# carry whatever stamp the last sync happened to leave — and a device log that
# names the wrong commit sends the next diagnosis in the wrong direction.
# gen-version-header.sh is a pure function of UPSTREAM.pin (D-066) and rewrites
# the file only when it actually changes, so this is a no-op between pin bumps
# and the game modules built yesterday still agree with the engine built today.
echo "==> refreshing version header"
"$ROOT/scripts/gen-version-header.sh"
VERSION_HASH="$("$ROOT/scripts/gen-version-header.sh" --print-hash)"
echo "$VERSION_HASH" > "$OUT/.version-header-sha256"

# Objects whose source is no longer in the manifest are deleted before
# compiling (D-110). The archive step globs obj/*.o, so after a pin bump that
# removed or renamed an upstream file the stale object would otherwise be
# linked in silently — duplicate symbols at best, last pin's code at worst.
EXPECTED_OBJS="$( { echo "$ENGINE_SRC"; echo "$RENDER_SRC"; } | grep . | tr '/' '_' | sed 's/$/.o/'
	printf '%s\n' glew_dedicated.o stb_vorbis.o )"
stale=0
for o in "$OUT"/obj/*.o; do
	[ -e "$o" ] || continue
	if ! grep -qxF -- "$(basename "$o")" <<< "$EXPECTED_OBJS"; then
		rm -f "$o"; stale=$((stale + 1))
	fi
done
[ "$stale" -eq 0 ] || echo "==> removed $stale stale object(s) no longer in the source manifest"

echo "==> compiling $n_engine engine + $n_render renderer sources for $LANE (-j$JOBS)"

# One compile per source, fanned out with xargs, each writing its own log so a
# failure can be read without untangling interleaved parallel output.
#
# bash cannot export arrays, so the flag arrays are baked into a small generated
# wrapper (%q-quoted) rather than smuggled through the environment.
WRAP="$OUT/.compile-one.sh"
{
	echo '#!/usr/bin/env bash'
	echo 'set -euo pipefail'
	printf 'TREE=%q\nOUT=%q\nCXX=%q\n' "$TREE" "$OUT" "$CXX"
	printf 'CXXFLAGS=('; printf '%q ' "${CXXFLAGS[@]}"; echo ')'
	printf 'DEFS=(';    printf '%q ' "${DEFS[@]}";    echo ')'
	printf 'RENDERER_DEFS=('; printf '%q ' "${RENDERER_DEFS[@]}"; echo ')'
	printf 'INCS=(';    printf '%q ' "${INCS[@]}";    echo ')'
	printf 'ENGINE_DEFS=('; printf '%q ' "${ENGINE_DEFS[@]}"; echo ')'
	printf 'CFLAGS=('; printf '%q ' "${CFLAGS[@]}"; echo ')'
	printf 'CC=%q\n' "$CC"
	cat <<'BODY'
src="$1"; kind="$2"
path="$TREE/$src"
obj="$OUT/obj/$(echo "$src" | tr '/' '_').o"
log="$OUT/logs/$(echo "$src" | tr '/' '_').log"
extra=()
case "$kind" in
	renderer) extra=("${RENDERER_DEFS[@]}") ;;
	engine)   extra=("${ENGINE_DEFS[@]}") ;;
esac
# Plain C (the in-tree jpeg-6 sources are .c) must not get -std=c++20 or the
# C++ precompiled header; compiling them as C++ mangles their symbols and the
# link then fails on _jpeg_* being undefined.
if [ "${src##*.}" = "c" ]; then
	if ! "$CC" -x c "${CFLAGS[@]}" "${DEFS[@]}" ${extra[@]+"${extra[@]}"} \
		"${INCS[@]}" -c "$path" -o "$obj" > "$log" 2>&1; then
		echo "FAILED $src" >&2
		grep -E 'error:' "$log" | head -5 >&2
		exit 1
	fi
	exit 0
fi
lang=(-x c++)
case "$src" in *.m|*.mm) lang=(-x objective-c++) ;; esac
if ! "$CXX" "${lang[@]}" "${CXXFLAGS[@]}" "${DEFS[@]}" ${extra[@]+"${extra[@]}"} \
	"${INCS[@]}" -c "$path" -o "$obj" > "$log" 2>&1; then
	echo "FAILED $src" >&2
	grep -E 'error:' "$log" | head -5 >&2
	exit 1
fi
BODY
} > "$WRAP"
chmod +x "$WRAP"

fail=0
echo "$ENGINE_SRC" | grep . | xargs -P "$JOBS" -I{} "$WRAP" {} engine || fail=1
echo "$RENDER_SRC" | grep . | xargs -P "$JOBS" -I{} "$WRAP" {} renderer || fail=1
[ "$fail" -eq 0 ] || { echo "FATAL: compilation failed" >&2; exit 1; }

# GLEW, in its "dedicated" flavour. The engine references GLEW extension
# variables from R_InitOpenGL even in a Vulkan build, but iOS links no GL at
# all. Upstream already solved this for its GL-free dedicated-server and Vulkan
# module targets: GLAPI=extern drops the dllimport decoration so plain stub
# definitions satisfy the GL 1.1 references, and OPENQ4_GLEW_SDL3_LOADER takes
# precedence over the NSGL branch so nothing reaches for OpenGL.framework.
echo "==> compiling glew (dedicated, GL-free)"
"$CC" -x c -isysroot "$SDK" "${TARGET_FLAGS[@]}" -O2 -DNDEBUG -Wno-everything \
	-DGLEW_NO_GLU -DOPENQ4_GLEW_SDL3_LOADER -DGLAPI=extern \
	-I"$TREE/subprojects/glew/include" \
	-c "$TREE/subprojects/glew/src/glew.c" -o "$OUT/obj/glew_dedicated.o" \
	> "$OUT/logs/glew.log" 2>&1 || { tail -20 "$OUT/logs/glew.log"; echo "FATAL: glew failed" >&2; exit 1; }

# Plain C dependencies that meson builds as their own static libraries:
#   stb_vorbis  Ogg Vorbis decoding (music)
echo "==> compiling C dependencies (stb_vorbis)"
compile_c() { # <src> <out-name> [extra flags...]
	local src="$1" name="$2"; shift 2
	"$CC" -x c -isysroot "$SDK" "${TARGET_FLAGS[@]}" -O2 -DNDEBUG -Wno-everything \
		"$@" -c "$src" -o "$OUT/obj/$name.o" > "$OUT/logs/$name.log" 2>&1 \
		|| { tail -20 "$OUT/logs/$name.log"; echo "FATAL: $name failed" >&2; exit 1; }
}
compile_c "$TREE/subprojects/stb_vorbis/stb_vorbis.c" stb_vorbis -I"$TREE/subprojects/stb_vorbis"
# volk.c is deliberately NOT compiled on iOS. ios/compat/volk.h replaces it with
# direct calls into statically linked MoltenVK — see D-013 for why the two
# cannot share a symbol namespace.

echo "==> archiving"
# libtool, not ar: macOS ar flattens duplicate member basenames and silently
# drops objects (a documented program-wide trap).
"$LIBTOOL" -static -o "$OUT/libopenq4.a" "$OUT"/obj/*.o

# D-089's assertion, made automatic rather than done by hand once (D-090).
#
# The entry point is the one thing that differs per PLATFORM rather than per
# lane, and it is set by a -D that reaches the compiler through a synced source
# tree. This script does not re-run sync-overlay.sh, so a stale build/src-ios —
# one predating the OPENQ4_SWIFT_MAIN hunks of overlay patch 0002 — compiles an
# archive that exports `main` on a visionOS lane, links into the SwiftUI app
# without a word, and fails only at the very end with an undefined
# `_openq4_engine_main`. It cost a build round to find. Assert it here instead.
echo "==> asserting the entry point"
case "$LANE" in
	visionos|visionos-sim) WANT=_openq4_engine_main ; UNWANT=_main ;;
	*)                     WANT=_main               ; UNWANT=_openq4_engine_main ;;
esac
SYMS="$(nm -g "$OUT/libopenq4.a" 2>/dev/null | awk '$2 == "T" { print $3 }')"
grep -qx -- "$WANT" <<< "$SYMS" || {
	echo "FATAL: $OUT/libopenq4.a does not export $WANT." >&2
	echo "       The overlay is probably stale — run scripts/sync-overlay.sh." >&2
	exit 1; }
! grep -qx -- "$UNWANT" <<< "$SYMS" || {
	echo "FATAL: $OUT/libopenq4.a exports $UNWANT, which this lane must NOT have." >&2
	echo "       The overlay is probably stale — run scripts/sync-overlay.sh." >&2
	exit 1; }
echo "    $WANT present, $UNWANT absent"

echo
echo "IOS ENGINE OK ($LANE)"
echo "  $OUT/libopenq4.a  $(ls -lh "$OUT/libopenq4.a" | awk '{print $5}')  ($(ls "$OUT"/obj/*.o | wc -l | tr -d ' ') objects)"
lipo -info "$OUT/libopenq4.a"
