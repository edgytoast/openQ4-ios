#!/usr/bin/env bash
# build-ios-deps.sh — provision the static iOS dependencies openQ4 needs.
#
# Produces, under the lane's deps prefix (build/{ios,ios-sim,visionos,visionos-sim}-deps):
#   sdl-prefix/{lib/libSDL3.a, include/SDL3}    SDL3 3.4.10 (matches openQ4's wrap pin)
#   moltenvk/lib/libMoltenVK.a                  MoltenVK 1.4.1 ios-arm64 (static)
#   openal-prefix/{lib/libOpenAL.a, include/AL} OpenAL Soft 1.25.2, EFX-capable
#
# Deliberately NOT built here:
#   Vulkan headers  — openQ4 vendors its own (src/external/vulkan)
#   volk, VMA       — vendored in-tree (src/external/{volk,vma})
#   stb_vorbis      — vendored in-tree, single .c
#   GLEW            — GL only; the iOS build ships the Vulkan renderer (D-010)
#
# Version choices are not arbitrary. SDL3 is pinned to the same release openQ4's
# meson wrap uses and the macOS oracle links, so desk and device differ by
# platform only. MoltenVK 1.4.1 is what upstream pins AND what vkQuake-ios ships
# on device. OpenAL Soft 1.25.2 matches the oracle's Homebrew build, so EFX
# behaviour is comparable across the two (D-006).
#
# Idempotent; every step fails loud.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/vendor"
IOS_MIN=16.0
# visionOS floor (D-089, raised 2.0 -> 2.5 by D-090). 2.0 is the first SDK
# carrying the CompositorServices surface Phase 6's stereo mode is built on, but
# the PREBUILT MoltenVK 1.4.1 xrOS slices are stamped minos 2.5 and the app
# target's link step warns ("object file was built for newer visionOS version")
# against anything lower. Everything we compile is therefore built to 2.5 so the
# app cannot end up with a mixed minos set.
# NOT dhewm3's 26.0 — that floor was an ANGLE artifact and does not apply here.
XROS_MIN=2.5

# Lane: "device" (iphoneos), "sim" (iphonesimulator), "visionos" (xros) or
# "visionos-sim" (xrsimulator). The simulator lanes are what the charter's
# verification discipline runs against; the device lanes are what ships. They
# differ only in SDK, MoltenVK slice, deployment floor, and output directory.
#
# SDL_PATCHES names the overlay/patches-sdl/<set> a lane needs, or "" for none.
# All four Apple lanes take "apple". That is not a new change to iOS: when
# vendor/SDL was cloned from vkQuake-ios it arrived with vkQuake's two SDL
# patches already applied IN the working tree and never declared anywhere, so
# every iOS build this port has ever shipped already contains them. This round
# restored vendor/SDL to a pristine release-3.4.10 checkout and captured those
# exact edits as overlay/patches-sdl/apple/*, verified by diffing the
# reconstructed tree against a snapshot of the old dirty one (D-089). The iOS
# SDL sources are therefore byte-identical before and after.
LANE="${1:-device}"
case "$LANE" in
	device)       SDKNAME=iphoneos        ; MVK_SLICE=ios-arm64                   ; CFG_DIR=Release-iphoneos        ; DEPS="$ROOT/build/ios-deps"          ; CM_SYS=iOS      ; MIN="$IOS_MIN"  ; SDL_PATCHES=apple ;;
	sim)          SDKNAME=iphonesimulator ; MVK_SLICE=ios-arm64_x86_64-simulator  ; CFG_DIR=Release-iphonesimulator ; DEPS="$ROOT/build/ios-sim-deps"      ; CM_SYS=iOS      ; MIN="$IOS_MIN"  ; SDL_PATCHES=apple ;;
	visionos)     SDKNAME=xros            ; MVK_SLICE=xros-arm64                  ; CFG_DIR=Release-xros            ; DEPS="$ROOT/build/visionos-deps"     ; CM_SYS=visionOS ; MIN="$XROS_MIN" ; SDL_PATCHES=apple ;;
	visionos-sim) SDKNAME=xrsimulator     ; MVK_SLICE=xros-arm64_x86_64-simulator ; CFG_DIR=Release-xrsimulator     ; DEPS="$ROOT/build/visionos-sim-deps" ; CM_SYS=visionOS ; MIN="$XROS_MIN" ; SDL_PATCHES=apple ;;
	*) echo "usage: $0 [device|sim|visionos|visionos-sim]" >&2; exit 1 ;;
esac

SDL_TAG=release-3.4.10
OPENAL_TAG=1.25.2
MVK_VER=1.4.1

# A sibling port on the same machine (vkQuake-ios) may already vendor
# byte-identical sources. Cloning from it is an APFS copy-on-write operation
# (free, instant) and avoids re-downloading; the git remote / release download
# below is the clean-machine path. OPENQ4_SIBLING_VKQUAKE names that checkout
# (default: ~/dev/vkQuake-ios); set it EMPTY to force the network path, which is
# what the clean-clone drill does (D-113).
SIBLING_VKQUAKE="${OPENQ4_SIBLING_VKQUAKE-$HOME/dev/vkQuake-ios}"
SIBLING_SDL="${SIBLING_VKQUAKE:+$SIBLING_VKQUAKE/vendor/SDL}"
SIBLING_MVK="${SIBLING_VKQUAKE:+$SIBLING_VKQUAKE/vendor/moltenvk/MoltenVK.xcframework}"

mkdir -p "$DEPS" "$VENDOR"

command -v cmake >/dev/null || { echo "FATAL: cmake not installed (brew install cmake)" >&2; exit 1; }
command -v git   >/dev/null || { echo "FATAL: git not installed (xcode-select --install)" >&2; exit 1; }

say() { echo "== $*"; }
die() { echo "FATAL: $*" >&2; exit 1; }

# ---------------------------------------------------------------- sources ---

if [ ! -d "$VENDOR/SDL" ]; then
	if [ -n "$SIBLING_SDL" ] && [ -d "$SIBLING_SDL" ]; then
		say "cloning SDL3 source from sibling vkQuake-ios (APFS, $SDL_TAG)"
		cp -R -c "$SIBLING_SDL" "$VENDOR/SDL"
	else
		say "cloning SDL3 $SDL_TAG from upstream"
		git clone --depth 1 --branch "$SDL_TAG" https://github.com/libsdl-org/SDL.git "$VENDOR/SDL"
	fi
fi
# Guard against a sibling that has since moved: the whole point of the pin is
# that device and oracle run the same SDL.
if [ -d "$VENDOR/SDL/.git" ]; then
	have="$(git -C "$VENDOR/SDL" describe --tags --always 2>/dev/null || echo unknown)"
	[ "$have" = "$SDL_TAG" ] || echo "WARNING: vendor/SDL is at '$have', expected '$SDL_TAG'" >&2
fi

if [ ! -d "$VENDOR/openal-soft" ]; then
	say "cloning OpenAL Soft $OPENAL_TAG"
	git clone --depth 1 --branch "$OPENAL_TAG" https://github.com/kcat/openal-soft.git "$VENDOR/openal-soft"
fi

# --------------------------------------------------- SDL source for the lane ---
#
# vendor/SDL is a pristine upstream checkout and stays one (ground rule 1). A
# lane that needs local SDL changes gets a checksum-synced copy under
# build/sdl-src-<set> with overlay/patches-sdl/<set>/*.patch applied at
# --fuzz=0, failing loudly; a lane with SDL_PATCHES="" builds from vendor/SDL
# directly. The patch set is stamped beside the built prefix so editing a patch
# rebuilds SDL instead of silently re-using yesterday's archive.
SDL_SRC="$VENDOR/SDL"
SDL_STAMP="none"
if [ -n "$SDL_PATCHES" ]; then
	SDL_PATCH_DIR="$ROOT/overlay/patches-sdl/$SDL_PATCHES"
	[ -d "$SDL_PATCH_DIR" ] || die "no SDL patch set at $SDL_PATCH_DIR"
	SDL_SRC="$ROOT/build/sdl-src-$SDL_PATCHES"
	SDL_STAMP="$(cat "$SDL_PATCH_DIR"/*.patch | shasum -a 256 | awk '{print $1}')"
	say "syncing SDL3 source + '$SDL_PATCHES' patch set -> $(basename "$SDL_SRC")"
	mkdir -p "$SDL_SRC"
	rsync -rlpc --delete --exclude '.git/' "$VENDOR/SDL/" "$SDL_SRC/"
	sdl_applied=0
	for p in "$SDL_PATCH_DIR"/*.patch; do
		patch -p1 -d "$SDL_SRC" --fuzz=0 --forward --silent < "$p" \
			|| die "SDL patch failed to apply: $(basename "$p") (SDL moved? re-review, do not re-aim with fuzz)"
		echo "    applied $(basename "$p")"
		sdl_applied=$((sdl_applied + 1))
	done
	[ "$sdl_applied" -gt 0 ] || die "SDL patch set '$SDL_PATCHES' is empty"
fi
# A changed patch set invalidates the built archive; without this the prefix
# check below would keep an SDL built from the previous patch text forever.
if [ -f "$DEPS/.sdl-patch-stamp" ] && [ "$(cat "$DEPS/.sdl-patch-stamp")" != "$SDL_STAMP" ]; then
	say "SDL patch set changed — rebuilding SDL3"
	rm -rf "$DEPS/sdl-prefix" "$DEPS/sdl-build"
fi

if [ ! -f "$DEPS/moltenvk/lib/libMoltenVK.a" ]; then
	say "vendoring MoltenVK $MVK_VER ($MVK_SLICE, static)"
	MVK_XC="$VENDOR/moltenvk/MoltenVK.xcframework"
	if [ ! -d "$MVK_XC" ]; then
		if [ -n "$SIBLING_MVK" ] && [ -d "$SIBLING_MVK" ]; then
			mkdir -p "$VENDOR/moltenvk"
			cp -R -c "$SIBLING_MVK" "$MVK_XC"
		else
			TMP="$DEPS/mvk-dl"; rm -rf "$TMP"; mkdir -p "$TMP"
			curl -L --fail -o "$TMP/mvk.tar" \
				"https://github.com/KhronosGroup/MoltenVK/releases/download/v$MVK_VER/MoltenVK-all.tar"
			tar xf "$TMP/mvk.tar" -C "$TMP"
			XC="$(find "$TMP" -iname MoltenVK.xcframework -path '*static*' | head -1)"
			[ -d "$XC" ] || die "static MoltenVK.xcframework not found in the release archive"
			mkdir -p "$VENDOR/moltenvk"; cp -R "$XC" "$MVK_XC"; rm -rf "$TMP"
		fi
	fi
	SLICE="$MVK_XC/$MVK_SLICE/libMoltenVK.a"
	[ -f "$SLICE" ] || die "MoltenVK $MVK_SLICE slice missing at $SLICE"
	mkdir -p "$DEPS/moltenvk/lib"
	cp "$SLICE" "$DEPS/moltenvk/lib/"
fi
lipo -info "$DEPS/moltenvk/lib/libMoltenVK.a"

# -------------------------------------------------------------- SDL3 (iOS) ---

if [ ! -f "$DEPS/sdl-prefix/lib/libSDL3.a" ]; then
	say "building SDL3 static for $SDKNAME/arm64 (min $MIN)"
	cmake -S "$SDL_SRC" -B "$DEPS/sdl-build" -GXcode \
		-DCMAKE_SYSTEM_NAME="$CM_SYS" \
		-DCMAKE_OSX_SYSROOT="$SDKNAME" \
		-DCMAKE_OSX_ARCHITECTURES=arm64 \
		-DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN" \
		-DSDL_STATIC=ON -DSDL_SHARED=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF \
		-DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
		-DCMAKE_INSTALL_PREFIX="$DEPS/sdl-prefix" \
		> "$DEPS/sdl-cmake.log" 2>&1 || { tail -25 "$DEPS/sdl-cmake.log"; die "SDL3 configure failed"; }
	cmake --build "$DEPS/sdl-build" --config Release --target SDL3-static \
		> "$DEPS/sdl-build.log" 2>&1 || { tail -30 "$DEPS/sdl-build.log"; die "SDL3 build failed"; }

	mkdir -p "$DEPS/sdl-prefix/lib" "$DEPS/sdl-prefix/include/SDL3"
	cp "$DEPS/sdl-build/$CFG_DIR/libSDL3.a" "$DEPS/sdl-prefix/lib/"
	cp "$SDL_SRC/include/SDL3/"*.h "$DEPS/sdl-prefix/include/SDL3/"
	# SDL_revision.h is generated into the build tree, not the source tree.
	cp "$(find "$DEPS/sdl-build" -name SDL_revision.h | head -1)" "$DEPS/sdl-prefix/include/SDL3/"
fi
echo "$SDL_STAMP" > "$DEPS/.sdl-patch-stamp"
lipo -info "$DEPS/sdl-prefix/lib/libSDL3.a"

# The iOS main loop depends on this symbol existing (docs/port-surface.md §3).
# It is NOT relaxed for the visionOS lanes: SDL_platform_defines.h defines
# SDL_PLATFORM_IOS whenever TARGET_OS_IPHONE is set, and visionOS sets it, so
# the uikit video driver and its CADisplayLink callback are compiled on xrOS
# too. Asserted as a symbol below, not just as a declaration.
grep -q 'SDL_SetiOSAnimationCallback' "$DEPS/sdl-prefix/include/SDL3/SDL_system.h" \
	|| die "SDL3 headers lack SDL_SetiOSAnimationCallback — wrong version or platform"
nm -g "$DEPS/sdl-prefix/lib/libSDL3.a" 2>/dev/null | grep -q 'T _SDL_SetiOSAnimationCallback' \
	|| die "libSDL3.a does not define _SDL_SetiOSAnimationCallback — the uikit video driver was not built"

# -------------------------------------------------------- OpenAL Soft (iOS) ---

# openal-soft installs the archive lowercase as libopenal.a on this platform,
# whatever the CMake target is called. Probe for what it actually produces.
if [ -z "$(ls "$DEPS/openal-prefix/lib/"libopenal*.a 2>/dev/null || true)" ]; then
	say "building OpenAL Soft $OPENAL_TAG static for $SDKNAME/arm64 (min $MIN)"
	# -DHAVE_WFUNCTION_EFFECTS=FALSE pre-seeds openal-soft's
	# check_cxx_compiler_flag cache entry so it skips the probe and never adds
	# -Werror=function-effects (CMakeLists.txt:276-278, :411). Clang 21 (Xcode 26)
	# introduced that warning and openal-soft 1.25.2's own coreaudio.cpp trips it,
	# so the project fails to build against its own error flag. Passing
	# -Wno-... via CMAKE_CXX_FLAGS does not work: those land ahead of the
	# project's flags on the command line and get re-enabled.
	# -DMAC_OS_X_VERSION_MIN_REQUIRED=101300 disables openal-soft's aligned
	# operator new/delete shim (common/almalloc.cpp), which is meant only for
	# macOS < 10.13 and compiles into every iOS build because AvailabilityMacros.h
	# leaves that macro at MAC_OS_X_VERSION_10_5 (1050) on iOS. The shim allocates
	# with posix_memalign, which returns EINVAL for any alignment below
	# sizeof(void*) — so `::operator new[](n, align_val_t{4})` THROWS instead of
	# allocating. al::Effect and al::Filter are 4-byte aligned, so every
	# alGenEffects/alGenFilters reported AL_OUT_OF_MEMORY and EFX never came up
	# (D-067). Predefining the macro takes the #ifndef branch in
	# AvailabilityMacros.h, so the shim is simply not compiled; nothing else in
	# an iOS build consults it. Same defect family as D-060, root instead of leaf.
	# REQUIRE_COREAUDIO makes a missing backend a configure error. Without it,
	# openal-soft silently falls back to the Null device — which produces a
	# perfectly silent app reporting no errors anywhere, i.e. exactly the bug
	# this port spent a round chasing. Fail the build instead.
	# openal-soft 1.25.2's coreaudio backend already guards its mobile path with
	# `TARGET_OS_IOS || TARGET_OS_TV || TARGET_OS_VISION` (alc/backends/coreaudio.cpp:49),
	# so visionOS takes the CoreAudio branch and never reaches for
	# <IOKit/audio/IOAudioTypes.h>, which the xrOS SDK does not ship. dhewm3 had
	# to patch that line on an older release; we do not, and REQUIRE_COREAUDIO
	# below turns a regression back into a configure error rather than silence.
	cmake -S "$VENDOR/openal-soft" -B "$DEPS/openal-build" -GXcode \
		-DCMAKE_SYSTEM_NAME="$CM_SYS" \
		-DCMAKE_OSX_SYSROOT="$SDKNAME" \
		-DCMAKE_OSX_ARCHITECTURES=arm64 \
		-DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN" \
		-DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
		-DLIBTYPE=STATIC \
		-DALSOFT_REQUIRE_COREAUDIO=ON \
		-DALSOFT_UTILS=OFF -DALSOFT_EXAMPLES=OFF -DALSOFT_TESTS=OFF \
		-DALSOFT_INSTALL_EXAMPLES=OFF -DALSOFT_INSTALL_UTILS=OFF \
		-DHAVE_WFUNCTION_EFFECTS=FALSE \
		-DCMAKE_CXX_FLAGS="-DMAC_OS_X_VERSION_MIN_REQUIRED=101300" \
		-DCMAKE_INSTALL_PREFIX="$DEPS/openal-prefix" \
		> "$DEPS/openal-cmake.log" 2>&1 || { tail -30 "$DEPS/openal-cmake.log"; die "OpenAL configure failed"; }
	cmake --build "$DEPS/openal-build" --config Release --target install \
		> "$DEPS/openal-build.log" 2>&1 || { tail -30 "$DEPS/openal-build.log"; die "OpenAL build failed"; }
fi

OPENAL_LIB="$(ls "$DEPS/openal-prefix/lib/"libopenal*.a 2>/dev/null | head -1 || true)"
[ -n "$OPENAL_LIB" ] || die "no OpenAL static lib produced under $DEPS/openal-prefix/lib"
lipo -info "$OPENAL_LIB"

# EFX is the reason we build OpenAL Soft at all rather than using Apple's
# framework — without these headers openQ4's reverb path compiles out entirely
# (the OPENQ4_OPENAL_EFX_SUPPORTED gate). See DECISIONS D-006.
[ -f "$DEPS/openal-prefix/include/AL/efx.h" ] \
	|| die "OpenAL prefix has no AL/efx.h — EFX reverb would silently compile out"

echo
echo "IOS DEPS OK ($LANE): $DEPS"
echo "  SDL3       $(ls -lh "$DEPS/sdl-prefix/lib/libSDL3.a" | awk '{print $5}')"
echo "  MoltenVK   $(ls -lh "$DEPS/moltenvk/lib/libMoltenVK.a" | awk '{print $5}')"
echo "  OpenAL     $(ls -lh "$OPENAL_LIB" | awk '{print $5}')  ($(basename "$OPENAL_LIB"))"
