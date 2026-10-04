#!/usr/bin/env bash
# stage-bundle-content.sh — put the runtime content into an openQ4.app bundle.
#
#   scripts/stage-bundle-content.sh <path/to/openQ4.app> [lane]
#
# `lane` picks which build/<lane>/modules the game dylibs come from and
# defaults to "device", so every existing caller is unchanged.
#
# ONE definition of "what content the app ships", sourced by both
# build-ios-app.sh (simulator/device builds) and publish-ota.sh (archives).
#
# It exists because those two had separate copies of the list and they drifted:
# publish-ota.sh staged pak0/pak1/mod.json but not openq4_profile_ios.cfg, so
# every OTA build the maintainer installed ran with the entire iOS platform profile
# missing — com_maxfps, gyro, always-run, EFX, swap interval and the audio
# settings all silently on engine defaults. Worse, it was invisible: the engine
# still printed "Selecting ios platform profile." because the cvar was set; only
# the absence of "execing openq4_profile_ios.cfg" gave it away, and nothing
# checked for that. Several fixes recorded as "shipped" were never on the device.
#
# So: one list, one staging path, and an assertion at the end that every file
# that must be present actually is.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APP="${1:-}"
[ -n "$APP" ] && [ -d "$APP" ] || { echo "FATAL: usage: $0 <openQ4.app> [lane]" >&2; exit 1; }

# Asserted, not defaulted-through: a typo'd lane must not silently stage the
# iOS modules into a visionOS bundle, which links and runs and is wrong.
LANE="${2:-device}"
case "$LANE" in
	device)       MODDIR="$ROOT/build/ios/modules" ;;
	sim)          MODDIR="$ROOT/build/ios-sim/modules" ;;
	visionos)     MODDIR="$ROOT/build/visionos/modules" ;;
	visionos-sim) MODDIR="$ROOT/build/visionos-sim/modules" ;;
	*) echo "FATAL: unknown lane '$LANE' (device|sim|visionos|visionos-sim)" >&2; exit 1 ;;
esac

# One answer to "which packs" for every script (D-113): scripts/paks.sh.
. "$ROOT/scripts/paks.sh"
ORACLE_PAKS="$(openq4_paks_dir)"
PROFILE="$ROOT/ios/baseoq4/openq4_profile_ios.cfg"
MODULES="$MODDIR"

mkdir -p "$APP/baseoq4" "$APP/Frameworks"

echo "==> staging baseoq4 runtime packs"
for f in pak0.pk4 pak1.pk4 mod.json; do
	[ -f "$ORACLE_PAKS/$f" ] || { echo "FATAL: missing $ORACLE_PAKS/$f" >&2; exit 1; }
	# -c: skip the copy when content already matches, so repeated builds do not
	# re-write 560 MB every time.
	cp -c "$ORACLE_PAKS/$f" "$APP/baseoq4/$f" 2>/dev/null || cp "$ORACLE_PAKS/$f" "$APP/baseoq4/$f"
done

echo "==> staging openq4_profile_ios.cfg"
[ -f "$PROFILE" ] || { echo "FATAL: missing $PROFILE" >&2; exit 1; }
cp "$PROFILE" "$APP/baseoq4/openq4_profile_ios.cfg"

echo "==> staging the touch-scale demo library gui"
# A LOOSE override beside the paks, exactly like openq4_profile_ios.cfg, and for
# the same reason: pak0's MD5 is verified by the engine and rebuilding it belongs
# to the oracle meson tree. The engine searches directories before pk4s
# (FileSystem.cpp OpenFileReadFlags: the `search->dir` branch runs first, and a
# .gui from a directory is refused only under fs_restrict / serverPaks, neither
# of which a single-player iOS client has), so this file wins over pak0's copy
# without touching pak0 at all. Verified in the simulator, not assumed (D-086).
mkdir -p "$APP/baseoq4/guis"
python3 "$ROOT/scripts/gen-ios-demo-menu-gui.py" \
	"$ROOT/vendor/openQ4/content/baseoq4/pak0/guis/demo_menu.gui" \
	"$APP/baseoq4/guis/demo_menu.gui"

echo "==> staging game modules"
ls "$MODULES"/*.dylib >/dev/null 2>&1 || { echo "FATAL: no game modules in $MODULES" >&2; exit 1; }
cp "$MODULES"/*.dylib "$APP/Frameworks/"

echo "==> staging licence notices"
# D-113: every installed copy carries the licence split and the full text of
# every statically linked component's licence — upstream's macOS app does the
# same for OpenAL Soft (Resources/licenses). Copied fresh each time so a
# removed file cannot linger in an incremental bundle.
for f in "$ROOT/LICENSE" "$ROOT/NOTICE.md" "$ROOT/licenses/README.md"; do
	[ -f "$f" ] || { echo "FATAL: missing $f" >&2; exit 1; }
done
rm -rf "$APP/licenses"
mkdir -p "$APP/licenses"
cp -R "$ROOT/licenses/." "$APP/licenses/"
cp "$ROOT/LICENSE" "$APP/licenses/LICENSE"
cp "$ROOT/NOTICE.md" "$APP/licenses/NOTICE.md"

# Assert, rather than trust the copies above. This is the check whose absence
# let a missing profile ship repeatedly.
for required in \
	"$APP/baseoq4/pak0.pk4" \
	"$APP/baseoq4/pak1.pk4" \
	"$APP/baseoq4/openq4_profile_ios.cfg" \
	"$APP/baseoq4/guis/demo_menu.gui" \
	"$APP/Frameworks/game-sp_arm64.dylib" \
	"$APP/Frameworks/game-mp_arm64.dylib" \
	"$APP/licenses/LICENSE" \
	"$APP/licenses/NOTICE.md" \
	"$APP/licenses/openQ4-game/EULA.Development Kit.rtf" \
	"$APP/licenses/openal-soft/COPYING" \
	"$APP/licenses/MoltenVK/LICENSE"
do
	[ -f "$required" ] || { echo "FATAL: not staged: $required" >&2; exit 1; }
done
echo "==> bundle content staged and verified"
