#!/usr/bin/env bash
# version-strings.sh — the ONE derivation of the app's two version strings.
#
#   eval "$(scripts/version-strings.sh)"     -> MARKETING_VERSION, CURRENT_PROJECT_VERSION
#   scripts/version-strings.sh --print       -> "<marketing> <build>"
#
# Why this file exists (D-091). ios/Info.plist and ios/Info-visionos.plist used
# to hardcode CFBundleShortVersionString 0.1.0 / CFBundleVersion 1, while
# publish-ota.sh passed MARKETING_VERSION="$PUBLISH_VERSION" on the xcodebuild
# command line. A literal in the plist ignores the build setting, so every build
# this port has ever published — including 0.1.0.53 on the hub — reported 0.1.0
# and build 1 inside its own bundle. SideStore compares
# CFBundleShortVersionString, so that had to be fixed before the first GitHub
# release or updates would silently stop.
#
# Both plists now use $(MARKETING_VERSION) / $(CURRENT_PROJECT_VERSION) and
# every lane passes both, derived HERE and nowhere else.
#
#   MARKETING_VERSION       = VERSION[.DEV_ITERATION]      (versioning
#                             rules: X.Y.Z for a public release, X.Y.Z.N
#                             for an OTA dev build). Identical to the
#                             PUBLISH_VERSION publish-ota.sh stages with.
#   CURRENT_PROJECT_VERSION = <release ordinal>.<DEV_ITERATION>.<resource build>
#                             CFBundleVersion allows AT MOST three
#                             period-separated integers (Apple's Info.plist
#                             reference; a review caught the first cut of this
#                             file emitting five). The release ordinal is
#                             major*10000 + minor*100 + patch, so it orders
#                             like VERSION; DEV_ITERATION is 0 for a public
#                             release and N for X.Y.Z.N; the resource build is
#                             gen-version-header.sh's pin-derived
#                             OPENQ4_VERSION_RESOURCE_BUILD — the same number
#                             the engine banner and the game modules'
#                             BUILD_NUMBER carry. So CFBundleVersion names the
#                             exact publish AND the exact upstream pin, and it
#                             only ever increases: 0.1.0 -> 100.0.b, 0.1.0.54
#                             -> 100.54.b, 0.1.1 -> 101.0.b.
#
# The version is OURS and comes from these files — NEVER from a built app
# (`defaults read` on a post-archive bundle reads a dangling symlink; four
# wrong-version incidents program-wide). Reading the built plist back to ASSERT
# it matches these files is the opposite of that, and the build scripts do it.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[ -f "$ROOT/VERSION" ]       || { echo "FATAL: missing $ROOT/VERSION" >&2; exit 1; }
[ -f "$ROOT/DEV_ITERATION" ] || { echo "FATAL: missing $ROOT/DEV_ITERATION" >&2; exit 1; }

VERSION="$(tr -d ' \n' < "$ROOT/VERSION")"
DEV_ITERATION="$(tr -d ' \n' < "$ROOT/DEV_ITERATION")"

# Release dry runs only (D-113): scripts/release.sh --version-override X.Y.Z
# exports OPENQ4_VERSION_OVERRIDE so a rehearsal can build a throwaway public
# version WITHOUT touching VERSION / DEV_ITERATION on disk. It means "X.Y.Z,
# public" (DEV_ITERATION 0) and is refused unless it is three numbers. Never
# set it for a build anyone installs — release.sh refuses to upload one.
if [ -n "${OPENQ4_VERSION_OVERRIDE:-}" ]; then
	case "$OPENQ4_VERSION_OVERRIDE" in
		*[!0-9.]*|.*|*.|*..*) echo "FATAL: OPENQ4_VERSION_OVERRIDE '$OPENQ4_VERSION_OVERRIDE' is not X.Y.Z" >&2; exit 1 ;;
	esac
	[ "$(printf '%s' "$OPENQ4_VERSION_OVERRIDE" | tr -cd . | wc -c | tr -d ' ')" = 2 ] \
		|| { echo "FATAL: OPENQ4_VERSION_OVERRIDE '$OPENQ4_VERSION_OVERRIDE' is not X.Y.Z" >&2; exit 1; }
	echo "!!  version-strings: OPENQ4_VERSION_OVERRIDE=$OPENQ4_VERSION_OVERRIDE (dry run; VERSION/DEV_ITERATION ignored)" >&2
	VERSION="$OPENQ4_VERSION_OVERRIDE"
	DEV_ITERATION=0
fi

case "$VERSION" in
	[0-9]*.[0-9]*.[0-9]*) ;;
	*) echo "FATAL: VERSION is '$VERSION', expected X.Y.Z" >&2; exit 1 ;;
esac
case "$DEV_ITERATION" in
	''|*[!0-9]*) echo "FATAL: DEV_ITERATION is '$DEV_ITERATION', expected an integer" >&2; exit 1 ;;
esac

if [ "$DEV_ITERATION" != "0" ]; then
	MARKETING_VERSION="${VERSION}.${DEV_ITERATION}"
else
	MARKETING_VERSION="$VERSION"
fi

# Pin-derived, identical to the engine header's OPENQ4_VERSION_RESOURCE_BUILD.
# Parsed out of the generated header rather than recomputed, so the two can
# never drift apart.
HEADER="$ROOT/build/ios-gen/openq4_version_generated.h"
"$ROOT/scripts/gen-version-header.sh" --print-hash > /dev/null
RESOURCE_BUILD="$(sed -n 's/^#define OPENQ4_VERSION_RESOURCE_BUILD //p' "$HEADER" | tr -d ' \r')"
case "$RESOURCE_BUILD" in
	''|*[!0-9]*) echo "FATAL: no OPENQ4_VERSION_RESOURCE_BUILD in $HEADER" >&2; exit 1 ;;
esac

IFS=. read -r V_MAJOR V_MINOR V_PATCH <<< "$VERSION"
RELEASE_ORDINAL=$(( V_MAJOR * 10000 + V_MINOR * 100 + V_PATCH ))
CURRENT_PROJECT_VERSION="${RELEASE_ORDINAL}.${DEV_ITERATION}.${RESOURCE_BUILD}"

if [ "${1:-}" = "--print" ]; then
	echo "$MARKETING_VERSION $CURRENT_PROJECT_VERSION"
else
	printf 'MARKETING_VERSION=%s\nCURRENT_PROJECT_VERSION=%s\n' \
		"$MARKETING_VERSION" "$CURRENT_PROJECT_VERSION"
fi
