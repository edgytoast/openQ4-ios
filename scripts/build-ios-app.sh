#!/usr/bin/env bash
# build-ios-app.sh — generate the Xcode project and link the openQ4 app.
#
#   scripts/build-ios-app.sh [device|sim|visionos|visionos-sim] [--public]
#
# --public (or OPENQ4_PUBLIC_BUILD=1) builds the PUBLIC flavour (D-113): the
# console bridge listener, its `!` commands, the openq4://console/ deep link
# and the onboarding test levers are compiled OUT (OPENQ4_PUBLIC_BUILD=1), and
# the bundle lands in build/<lane>-app-public so it can never be mistaken for
# the dev build of the same lane. Without it this is the dev build, exactly as
# before. scripts/release.sh archives the public flavour for a GitHub release.
#
# The engine is already a static archive by this point (build-ios-engine.sh);
# this step only links it into an app bundle with SDL3, MoltenVK and OpenAL.
#
# The simulator lanes override library paths and the target on the xcodebuild
# command line rather than in project.yml, so the shipping (device) configuration
# of each platform stays the single source of truth and cannot drift to match a
# test lane.
#
# Two platforms, two targets, two schemes (D-090). `openQ4` is the iOS app,
# `openQ4-visionOS` the visionOS one; they share the shell sources, the bundle
# id and the engine archive's shape, and nothing else.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOSDIR="$ROOT/ios"

LANE=device
PUBLIC="${OPENQ4_PUBLIC_BUILD:-0}"
for a in "$@"; do
	case "$a" in
		--public) PUBLIC=1 ;;
		device|sim|visionos|visionos-sim) LANE="$a" ;;
		*) echo "usage: $0 [device|sim|visionos|visionos-sim] [--public]" >&2; exit 1 ;;
	esac
done
case "$PUBLIC" in 0|1) ;; *) echo "FATAL: OPENQ4_PUBLIC_BUILD must be 0 or 1" >&2; exit 1 ;; esac
SCHEME=openQ4
case "$LANE" in
	device)       SDKNAME=iphoneos        ; ENGDIR="$ROOT/build/ios"           ; DEPS="$ROOT/build/ios-deps"           ; CFG=Release-iphoneos ;;
	sim)          SDKNAME=iphonesimulator ; ENGDIR="$ROOT/build/ios-sim"       ; DEPS="$ROOT/build/ios-sim-deps"       ; CFG=Release-iphonesimulator ;;
	visionos)     SDKNAME=xros            ; ENGDIR="$ROOT/build/visionos"      ; DEPS="$ROOT/build/visionos-deps"      ; CFG=Release-xros        ; SCHEME=openQ4-visionOS ;;
	visionos-sim) SDKNAME=xrsimulator     ; ENGDIR="$ROOT/build/visionos-sim"  ; DEPS="$ROOT/build/visionos-sim-deps"  ; CFG=Release-xrsimulator ; SCHEME=openQ4-visionOS ;;
	*) echo "usage: $0 [device|sim|visionos|visionos-sim]" >&2; exit 1 ;;
esac

[ -f "$ENGDIR/libopenq4.a" ] || { echo "FATAL: run scripts/build-ios-engine.sh $LANE first" >&2; exit 1; }
command -v xcodegen >/dev/null || { echo "FATAL: xcodegen not installed (brew install xcodegen)" >&2; exit 1; }

# D-066: the engine and the two game modules must be compiled against the SAME
# openq4_version_generated.h, or the modules' BUILD_NUMBER disagrees with the
# build the app claims to be and every savegame is refused at load. The modules
# shipped stale for a month behind an "does it exist" check; this is that check
# made honest. Both sides stamp the header's sha256 when they build.
VERSION_HASH="$("$ROOT/scripts/gen-version-header.sh" --print-hash)"
check_stamp() { # <label> <stamp file> <fix command>
	local label="$1" stamp="$2" fix="$3"
	[ -f "$stamp" ] || {
		echo "FATAL: $label was built before version stamping, or is incomplete." >&2
		echo "       run: $fix" >&2; exit 1; }
	[ "$(cat "$stamp")" = "$VERSION_HASH" ] || {
		echo "FATAL: $label is STALE — built against a different version header." >&2
		echo "       stamped $(cut -c1-12 < "$stamp")…, current ${VERSION_HASH:0:12}…" >&2
		echo "       run: $fix" >&2; exit 1; }
}
check_stamp "the engine archive" "$ENGDIR/.version-header-sha256" \
	"scripts/build-ios-engine.sh $LANE"
check_stamp "the game modules" "$ENGDIR/modules/.version-header-sha256" \
	"scripts/build-ios-game-modules.sh $LANE both"

# D-091: the two version strings are derived in ONE place and passed to every
# lane, because ios/Info{,-visionos}.plist now reference them as build settings
# instead of hardcoding 0.1.0 / 1. Asserted against the built plist below.
eval "$("$ROOT/scripts/version-strings.sh")"
[ -n "${MARKETING_VERSION:-}" ] && [ -n "${CURRENT_PROJECT_VERSION:-}" ] \
	|| { echo "FATAL: scripts/version-strings.sh produced no version" >&2; exit 1; }

if [ "$PUBLIC" = 1 ]; then
	BUILDROOT="$ROOT/build/${LANE}-app-public"
else
	BUILDROOT="$ROOT/build/${LANE}-app"
fi
mkdir -p "$BUILDROOT"

echo "==> generating Xcode project"
( cd "$IOSDIR" && xcodegen generate --quiet )

# xcodebuild does not dependency-track a library resolved from a search path, so
# a rebuilt engine archive would otherwise ship stale inside a cached .app.
APP_BIN="$BUILDROOT/$CFG/openQ4.app/openQ4"
[ -f "$APP_BIN" ] && rm -f "$APP_BIN"

FLAVOUR=dev; [ "$PUBLIC" = 1 ] && FLAVOUR=public
echo "==> linking openQ4.app ($LANE, $FLAVOUR)"
XCARGS=(
	-project "$IOSDIR/openQ4.xcodeproj"
	-scheme "$SCHEME"
	-configuration Release
	-sdk "$SDKNAME"
	-derivedDataPath "$BUILDROOT/dd"
	CONFIGURATION_BUILD_DIR="$BUILDROOT/$CFG"
	ARCHS=arm64
	MARKETING_VERSION="$MARKETING_VERSION"
	CURRENT_PROJECT_VERSION="$CURRENT_PROJECT_VERSION"
)
# The visionOS lanes build arm64 only and ONLY_ACTIVE_ARCH=YES, per D-089's lane
# table: the xrOS slices we vendor are arm64 (the simulator one is fat, and the
# fat half we do not want is x86_64).
if [ "$LANE" = visionos ] || [ "$LANE" = visionos-sim ]; then
	XCARGS+=( ONLY_ACTIVE_ARCH=YES )
else
	XCARGS+=( ONLY_ACTIVE_ARCH=NO )
fi
# $(inherited) keeps the target's own definitions (the visionOS target's
# OPENQ4_VISIONOS / _SWIFT_MAIN / _3D) — asserted after the link below.
if [ "$PUBLIC" = 1 ]; then
	XCARGS+=( GCC_PREPROCESSOR_DEFINITIONS='$(inherited) OPENQ4_PUBLIC_BUILD=1' )
fi
# Device lanes sign; the team comes from scripts/signing.local.sh (D-113).
if [ "$LANE" = device ] || [ "$LANE" = visionos ]; then
	. "$ROOT/scripts/signing.sh"
	openq4_load_signing || exit 1
	XCARGS+=( DEVELOPMENT_TEAM="$OPENQ4_TEAM_ID" )
fi

# Every lane but the two DEVICE ones is a simulator lane: unsigned, and pointed
# at the lane's own engine + deps prefixes.
if [ "$LANE" = sim ] || [ "$LANE" = visionos-sim ]; then
	XCARGS+=(
		CODE_SIGNING_ALLOWED=NO
		CODE_SIGN_IDENTITY=""
		LIBRARY_SEARCH_PATHS="$ENGDIR $DEPS/sdl-prefix/lib $DEPS/moltenvk/lib $DEPS/openal-prefix/lib"
		OTHER_LDFLAGS="-ObjC -force_load $ENGDIR/libopenq4.a -lSDL3 -lMoltenVK -lopenal -lc++ -lz -liconv -Wl,-unexported_symbol,__ZnwmSt11align_val_t -Wl,-unexported_symbol,__ZnamSt11align_val_t -Wl,-unexported_symbol,__ZdlPvSt11align_val_t -Wl,-unexported_symbol,__ZdaPvSt11align_val_t -Wl,-unexported_symbol,__ZnwmSt11align_val_tRKSt9nothrow_t -Wl,-unexported_symbol,__ZnamSt11align_val_tRKSt9nothrow_t -Wl,-unexported_symbol,__ZdlPvSt11align_val_tRKSt9nothrow_t -Wl,-unexported_symbol,__ZdaPvSt11align_val_tRKSt9nothrow_t -Wl,-unexported_symbol,__ZdlPvmSt11align_val_t -Wl,-unexported_symbol,__ZdaPvmSt11align_val_t"
	)
fi

if ! xcodebuild "${XCARGS[@]}" build > "$BUILDROOT/xcodebuild.log" 2>&1; then
	echo "FATAL: xcodebuild failed" >&2
	grep -E 'error:|Undefined symbols|ld: ' "$BUILDROOT/xcodebuild.log" | head -30 >&2
	echo "(full log: $BUILDROOT/xcodebuild.log)" >&2
	exit 1
fi

APP="$BUILDROOT/$CFG/openQ4.app"
[ -d "$APP" ] || { echo "FATAL: no app bundle produced at $APP" >&2; exit 1; }

# An Xcode application target with no sources links nothing, emits a bundle
# containing only Info.plist, and still reports BUILD SUCCEEDED. Check for the
# executable explicitly rather than trusting the exit code.
[ -f "$APP/openQ4" ] || {
	echo "FATAL: bundle has no executable — the target linked nothing" >&2
	echo "       (does the app target still have sources?)" >&2
	exit 1
}

# openQ4's own runtime packs ship INSIDE the bundle — they are part of the
# engine, not user data, and the engine hard-fatals if their MD5s do not match
# the ones compiled into the binary. fs_basepath resolves to the .app, so a
# baseoq4/ directory here is exactly where the engine looks.
#
# This is also where the charter's pak1 size decision will land: pak1 is ~560 MB
# of baked light-grid and loadscreen data, which dominates the IPA.
# Shared with publish-ota.sh so the two cannot drift — see that script's header
# for what drifting cost.
# The lane is passed explicitly. It used to default to "device", so a simulator
# build staged the DEVICE game dylibs here and was only saved by the embedding
# step below copying the right ones over the top a few lines later.
"$ROOT/scripts/stage-bundle-content.sh" "$APP" "$LANE"

# The SP/MP game modules ship as dylibs in Frameworks/, signed with the app, and
# are dlopen'd by upstream's loader unmodified (D-014). The engine's iOS
# Sys_GetGameModuleRootDirectory points its trusted-root search here.
MODULES="$ENGDIR/modules"
if [ -d "$MODULES" ] && [ -n "$(ls "$MODULES"/*.dylib 2>/dev/null || true)" ]; then
	echo "==> embedding game modules"
	mkdir -p "$APP/Frameworks"
	cp "$MODULES"/*.dylib "$APP/Frameworks/"
	if [ "$LANE" = device ] || [ "$LANE" = visionos ]; then
		# The simulator does not enforce code signing; a device does. Each nested
		# Mach-O must be signed with the same identity as the app or dlopen is
		# refused at runtime — a failure that cannot reproduce on the simulator.
		SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
			| grep -m1 'Apple Development' | sed -E 's/.*\) ([A-F0-9]{40}) .*/\1/')"
		[ -n "$SIGN_ID" ] || { echo "FATAL: no Apple Development signing identity found" >&2; exit 1; }
		for dylib in "$APP/Frameworks"/*.dylib; do
			codesign --force --sign "$SIGN_ID" --timestamp=none "$dylib" \
				|| { echo "FATAL: failed to sign $(basename "$dylib")" >&2; exit 1; }
		done
		# Re-sign the app last: its signature seals the bundle contents, so
		# adding dylibs after xcodebuild invalidates it. Preserve the entitlements
		# and identifier Xcode already applied rather than supplying new ones —
		# passing --entitlements alongside --preserve-metadata=entitlements is
		# contradictory and fails with "cannot read entitlement data".
		codesign --force --sign "$SIGN_ID" --timestamp=none \
			--preserve-metadata=entitlements,identifier,flags \
			"$APP" || { echo "FATAL: failed to re-sign the app bundle" >&2; exit 1; }
		codesign --verify --deep --strict "$APP" \
			|| { echo "FATAL: bundle fails signature verification after re-sign" >&2; exit 1; }
	fi
else
	echo "!! no game modules at $MODULES — the engine will fatal at game load." >&2
	echo "   run scripts/build-ios-game-modules.sh $LANE both" >&2
fi

# D-091: assert the bundle says what VERSION + DEV_ITERATION say. This is a
# CHECK, not a derivation — the program rule forbids deriving a publish version
# FROM a built app; reading the built plist back to confirm it matches the files
# is the opposite, and it is the only thing that would have caught a plist
# quietly ignoring MARKETING_VERSION for the life of the port.
PLIST_SHORT="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Info.plist")"
PLIST_BUILD="$(plutil -extract CFBundleVersion raw -o - "$APP/Info.plist")"
[ "$PLIST_SHORT" = "$MARKETING_VERSION" ] || {
	echo "FATAL: built CFBundleShortVersionString is '$PLIST_SHORT', expected '$MARKETING_VERSION'" >&2
	plutil -p "$APP/Info.plist" | grep -i version >&2; exit 1; }
[ "$PLIST_BUILD" = "$CURRENT_PROJECT_VERSION" ] || {
	echo "FATAL: built CFBundleVersion is '$PLIST_BUILD', expected '$CURRENT_PROJECT_VERSION'" >&2
	plutil -p "$APP/Info.plist" | grep -i version >&2; exit 1; }

# Static MoltenVK is found by SDL via dlsym(RTLD_DEFAULT, "vkGetInstanceProcAddr").
# If that symbol is missing the app builds fine and dies at window creation, so
# assert it here rather than discovering it on a device.
#
# Captured to a variable first, NOT piped into `grep -q`. Under `set -o pipefail`
# that pipeline reports the failure of whichever stage failed, and `grep -q`
# exits at the first match — so `nm`, still writing, takes SIGPIPE, the pipeline
# returns 141, and the check reports "not exported" about a binary that exports
# it perfectly well. It only started failing on the visionOS lane because the
# match happens to land early enough in that binary's symbol table for nm to
# still be running; the same latent bug was always there on iOS.
EXPORTS="$(nm -gU "$APP/openQ4" 2>/dev/null)"
if ! grep -q vkGetInstanceProcAddr <<< "$EXPORTS"; then
	echo "FATAL: vkGetInstanceProcAddr not exported — MoltenVK will not be found at runtime" >&2
	exit 1
fi

# D-113: the public flavour must not contain the bridge, and the dev flavour
# must. Checked on the linked binary, not inferred from the flags.
"$ROOT/scripts/check-public-binary.sh" "$APP/openQ4" "$FLAVOUR" "$LANE" \
	|| { echo "FATAL: $FLAVOUR binary failed the bridge-surface check" >&2; exit 1; }

echo
echo "APP OK ($LANE, $FLAVOUR)"
echo "  $APP"
echo "  version $MARKETING_VERSION (build $CURRENT_PROJECT_VERSION)"
echo "  binary $(ls -lh "$APP/openQ4" | awk '{print $5}')   bundle $(du -sh "$APP" | cut -f1)"
