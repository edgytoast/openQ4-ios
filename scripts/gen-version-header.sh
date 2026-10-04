#!/usr/bin/env bash
# gen-version-header.sh — emit build/ios-gen/openq4_version_generated.h as a
# PURE FUNCTION OF UPSTREAM.pin (DECISIONS D-066).
#
#   scripts/gen-version-header.sh [--print-hash]
#
# Why this exists. Upstream's tools/build/openq4_version.py derives
# OPENQ4_VERSION_RESOURCE_BUILD from `git rev-list --count HEAD` of its
# --source-root. Our source root is build/src-ios, which is not a git repo, so
# git walks up and counts OUR repository — the number therefore rose with every
# commit we made. That number is the game modules' BUILD_NUMBER
# (src/framework/BuildVersion.h), and both savegame paths in
# game/gamesys/SaveGame.cpp refuse a payload whose build number differs from the
# running module's. So every commit invalidated every save, and any binary built
# at a different commit than the game modules disagreed with itself.
#
# The rule now: the resource build number is derived from the upstream pin and
# nothing else. It is identical for the engine and both game modules, and it
# does not move until UPSTREAM.pin moves.
#
# Derivation (documented so it can be reproduced by hand):
#
#   build = (first 8 hex digits of sha256("<engine commit>:<game commit>")
#            as an integer) % 65535 + 1          -> 1..65535
#
# A hash rather than a date: the pin is a pair of commits, the field is a
# 16-bit resource build, and two pins that differ must not collide. It is
# stable, reproducible on any machine, and needs no git history at all.
#
# The header is written only when its contents change, so an unchanged pin
# leaves the mtime alone and the staleness checks in build-ios-app.sh /
# publish-ota.sh stay meaningful.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TREE="$ROOT/build/src-ios"
VENDOR="$ROOT/vendor/openQ4"
GEN="$ROOT/build/ios-gen"
PIN="$ROOT/UPSTREAM.pin"
HEADER="$GEN/openq4_version_generated.h"

PRINT_HASH=0
[ "${1:-}" = "--print-hash" ] && PRINT_HASH=1

[ -f "$PIN" ] || { echo "FATAL: missing $PIN" >&2; exit 1; }
[ -x "$TREE/tools/build/openq4_version.py" ] || [ -f "$TREE/tools/build/openq4_version.py" ] \
	|| { echo "FATAL: run scripts/sync-overlay.sh first (no $TREE/tools)" >&2; exit 1; }

ENGINE_COMMIT="$(sed -n 's/^OPENQ4_COMMIT=//p' "$PIN" | head -1)"
GAME_COMMIT="$(sed -n 's/^OPENQ4_GAME_COMMIT=//p' "$PIN" | head -1)"
[ -n "$ENGINE_COMMIT" ] && [ -n "$GAME_COMMIT" ] \
	|| { echo "FATAL: could not read the commit pair out of $PIN" >&2; exit 1; }

RESOURCE_BUILD="$(python3 - "$ENGINE_COMMIT" "$GAME_COMMIT" <<'PY'
import hashlib, sys
pair = f"{sys.argv[1]}:{sys.argv[2]}".encode()
print(int(hashlib.sha256(pair).hexdigest()[:8], 16) % 65535 + 1)
PY
)"

# D-110: from v0.13.2 the build number is part of savegame acceptance. The
# engine refuses any v3 save whose payload build is below
# SESSION_OPENQ4_SAVEGAME_MINIMUM_SUPPORTED_BUILD (upstream's build numbers are
# commit counts, so the floor is "older than the first verified decoder"), and
# the game modules special-case INITIAL_RELEASE_BUILD_NUMBER (retail 1262). Our
# number is a hash of the pin, not a count, so it could land on either by
# chance — and then this build would refuse its OWN saves. Fail loudly instead.
SAVE_FLOOR="$(sed -n 's/^static const int SESSION_OPENQ4_SAVEGAME_MINIMUM_SUPPORTED_BUILD = \([0-9][0-9]*\);.*/\1/p' \
	"$VENDOR/src/framework/Session.cpp" | head -1)"
[ -n "$SAVE_FLOOR" ] || { echo "FATAL: no SESSION_OPENQ4_SAVEGAME_MINIMUM_SUPPORTED_BUILD in vendor/openQ4 Session.cpp — re-check D-110's build-number rule" >&2; exit 1; }
RETAIL_BUILD="$(sed -n 's/^const int INITIAL_RELEASE_BUILD_NUMBER = \([0-9][0-9]*\);.*/\1/p' \
	"$ROOT/vendor/openQ4-game/src/game/gamesys/SaveGame.h" | head -1)"
[ -n "$RETAIL_BUILD" ] || { echo "FATAL: no INITIAL_RELEASE_BUILD_NUMBER in vendor/openQ4-game SaveGame.h" >&2; exit 1; }
[ "$RESOURCE_BUILD" -ge "$SAVE_FLOOR" ] && [ "$RESOURCE_BUILD" -ne "$RETAIL_BUILD" ] || {
	echo "FATAL: pin-derived build number $RESOURCE_BUILD is below upstream's savegame floor $SAVE_FLOOR" >&2
	echo "       (or equals the retail build $RETAIL_BUILD): this build would refuse its own saves." >&2
	echo "       Decide a new derivation in DECISIONS.md before shipping this pin (D-066, D-110)." >&2
	exit 1; }

mkdir -p "$GEN"
TMP="$GEN/.openq4_version_generated.h.tmp"

# Upstream's generator still owns the header's SHAPE (field set, ordering,
# base-version parsing out of meson.build) so a pin bump that adds a field is
# picked up rather than silently dropped. We run it against vendor/openQ4 so the
# git metadata it embeds describes the PIN and not our working tree, then
# overwrite the four git-derived fields with the pin-derived values.
python3 "$TREE/tools/build/openq4_version.py" \
	--source-root "$VENDOR" --track dev --header-out "$TMP" > /dev/null \
	|| { echo "FATAL: version header generation failed" >&2; exit 1; }

SHORT_SHA="${ENGINE_COMMIT:0:8}"
MAJOR="$(sed -n 's/^#define OPENQ4_VERSION_MAJOR //p' "$TMP")"
MINOR="$(sed -n 's/^#define OPENQ4_VERSION_MINOR //p' "$TMP")"
PATCHV="$(sed -n 's/^#define OPENQ4_VERSION_PATCH //p' "$TMP")"
[ -n "$MAJOR" ] && [ -n "$MINOR" ] && [ -n "$PATCHV" ] \
	|| { echo "FATAL: upstream header has no MAJOR/MINOR/PATCH — did the generator change?" >&2; exit 1; }

# Ground rule 3: every scripted edit asserts its match count.
subst() { # <sed expression> <expected match count> <grep pattern>
	local expr="$1" want="$2" got
	got="$(grep -c "$3" "$TMP" || true)"
	[ "$got" = "$want" ] || { echo "FATAL: expected $want match(es) for '$3' in the generated header, got $got" >&2; exit 1; }
	sed -i '' "$expr" "$TMP"
}

subst "s/^#define OPENQ4_VERSION_RESOURCE_BUILD .*/#define OPENQ4_VERSION_RESOURCE_BUILD ${RESOURCE_BUILD}/" 1 '^#define OPENQ4_VERSION_RESOURCE_BUILD '
subst "s/^#define OPENQ4_VERSION_RESOURCE_COMMAS_STRING .*/#define OPENQ4_VERSION_RESOURCE_COMMAS_STRING \"${MAJOR}, ${MINOR}, ${PATCHV}, ${RESOURCE_BUILD}\"/" 1 '^#define OPENQ4_VERSION_RESOURCE_COMMAS_STRING '
subst "s/^#define OPENQ4_VERSION_RESOURCE_DOTTED .*/#define OPENQ4_VERSION_RESOURCE_DOTTED \"${MAJOR}.${MINOR}.${PATCHV}.${RESOURCE_BUILD}\"/" 1 '^#define OPENQ4_VERSION_RESOURCE_DOTTED '
subst "s/^#define OPENQ4_VERSION_GIT_SHA .*/#define OPENQ4_VERSION_GIT_SHA \"${SHORT_SHA}\"/" 1 '^#define OPENQ4_VERSION_GIT_SHA '
subst "s/^#define OPENQ4_VERSION_GIT_DIRTY .*/#define OPENQ4_VERSION_GIT_DIRTY 0/" 1 '^#define OPENQ4_VERSION_GIT_DIRTY '
subst "s/^#define OPENQ4_VERSION_COMMIT_COUNT .*/#define OPENQ4_VERSION_COMMIT_COUNT ${RESOURCE_BUILD}/" 1 '^#define OPENQ4_VERSION_COMMIT_COUNT '

# The version STRINGS also carry git metadata (+g<sha>[.dirty]); vendor/openQ4 is
# a clean shallow clone at the pin, so they already name the pinned commit. Assert
# it rather than trust it — a dirty vendor tree would leak ".dirty" into the
# shipped banner and make the build irreproducible.
grep -q "^#define OPENQ4_VERSION \".*g${SHORT_SHA}\"\$" "$TMP" || {
	echo "FATAL: generated OPENQ4_VERSION does not end at the pinned sha g${SHORT_SHA}:" >&2
	grep '^#define OPENQ4_VERSION ' "$TMP" >&2
	echo "       (is vendor/openQ4 dirty or at the wrong commit? re-run scripts/sync-overlay.sh)" >&2
	exit 1
}

if [ -f "$HEADER" ] && cmp -s "$TMP" "$HEADER"; then
	rm -f "$TMP"
else
	mv "$TMP" "$HEADER"
fi

HASH="$(shasum -a 256 "$HEADER" | awk '{print $1}')"
if [ "$PRINT_HASH" = 1 ]; then
	echo "$HASH"
else
	echo "    openq4_version_generated.h  build ${RESOURCE_BUILD} (pin ${SHORT_SHA})  sha256 ${HASH:0:12}"
fi
