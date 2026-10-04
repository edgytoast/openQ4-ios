#!/usr/bin/env bash
# gen-savegame-compat-header.sh — emit build/ios-gen/openq4_savegame_compat_generated.h
# as a PURE FUNCTION OF THE UPSTREAM PIN, never of our patched trees (D-084).
#
#   scripts/gen-savegame-compat-header.sh [--print-hash]
#
# Why this exists. Upstream's tools/build/generate_savegame_compat_header.py
# hashes every save-relevant source FILE under src/framework, src/sound, src/ui
# (engine) and src/game, src/mpgame (game modules), where "save-relevant" is a
# token grep over the whole file. Both of our overlays touch such files —
# Session.cpp on the engine side, Player.cpp on the game side (D-071) — so a
# stamp computed from the PATCHED trees moves the moment the overlay grows, and
# the engine (Session.cpp) plus both game modules (gamesys/SaveGame.cpp) then
# refuse every savegame written by an earlier build. The save FORMAT is
# unchanged; only the fingerprint moved.
#
# It did not bite yet only because build-ios-game-modules.sh generated the
# header once and then skipped it forever (`if [ ! -f ... ]`) — so the value on
# disk is whatever the FIRST build on this machine happened to produce, and a
# clean tree, a new machine, or a second build tree (the coming visionOS one)
# silently produces a different one. D-070 recorded that as a latent trap.
#
# The rule now, and it is the same rule as D-066's build number: the stamp is a
# function of pristine upstream at the pin and nothing else.
#
#   project-root     vendor/openQ4        (NOT build/src-ios)
#   game-stage-root  vendor/openQ4-game   (NOT .tmp/gamelibs_stage)
#   generator        vendor/openQ4's own copy, so the tool is pristine too
#
# Both vendor trees are clean shallow clones at the pin, so this is
# reproducible on any machine and in any build tree — which is the whole point.
#
# And it is ASSERTED, not merely computed: overlay/savegame-stamp.txt records
# the expected value and a mismatch is a hard, loud failure with instructions.
# A stamp that can move silently is exactly the hazard being fixed; the recorded
# value turns "the maintainer's saves just stopped loading" into a build error.
#
# The header is written only when its contents change, so an unchanged pin
# leaves the mtime alone and does not trigger a needless rebuild.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="$ROOT/vendor/openQ4"
GAME="$ROOT/vendor/openQ4-game"
GEN="$ROOT/build/ios-gen"
STAMP="$ROOT/overlay/savegame-stamp.txt"
HEADER="$GEN/openq4_savegame_compat_generated.h"
GENERATOR="$ENGINE/tools/build/generate_savegame_compat_header.py"

PRINT_HASH=0
[ "${1:-}" = "--print-hash" ] && PRINT_HASH=1

[ -f "$GENERATOR" ] || { echo "FATAL: missing $GENERATOR (is vendor/openQ4 populated?)" >&2; exit 1; }
[ -d "$GAME/src/game" ] || { echo "FATAL: missing $GAME/src/game (is vendor/openQ4-game populated?)" >&2; exit 1; }
[ -f "$STAMP" ] || { echo "FATAL: missing $STAMP — the recorded savegame stamp is not optional" >&2; exit 1; }

# First non-empty, non-comment line. Anything else in the file is prose for
# whoever bumps the pin.
EXPECT="$(grep -v '^[[:space:]]*#' "$STAMP" | tr -d '[:space:]' | grep . | head -1 || true)"
[ -n "$EXPECT" ] || { echo "FATAL: $STAMP contains no stamp value" >&2; exit 1; }

mkdir -p "$GEN"
TMP="$GEN/.openq4_savegame_compat_generated.h.tmp"
rm -f "$TMP"

python3 "$GENERATOR" \
	--project-root "$ENGINE" --game-stage-root "$GAME" \
	--header-out "$TMP" > /dev/null \
	|| { echo "FATAL: savegame compat header generation failed" >&2; exit 1; }
[ -f "$TMP" ] || { echo "FATAL: savegame compat header was not written" >&2; exit 1; }

GOT="$(sed -n 's/^#define OPENQ4_SAVEGAME_COMPAT_SOURCE_HASH "\(.*\)"$/\1/p' "$TMP")"
COUNT="$(sed -n 's/^#define OPENQ4_SAVEGAME_COMPAT_SOURCE_FILE_COUNT //p' "$TMP")"
[ -n "$GOT" ] && [ -n "$COUNT" ] \
	|| { echo "FATAL: could not read the stamp out of the generated header — did upstream's generator change shape?" >&2; exit 1; }

if [ "$GOT" != "$EXPECT" ]; then
	rm -f "$TMP"
	cat >&2 <<EOF
FATAL: the savegame compatibility stamp does not match the recorded value.

  recorded (overlay/savegame-stamp.txt)  $EXPECT
  computed from the pin                  $GOT  ($COUNT files)

Every existing savegame — on the maintainer's phone included — is keyed to the recorded
value and will be REFUSED by a build carrying the computed one. The save format
itself is almost certainly unchanged; this is a fingerprint over source files.

If UPSTREAM.pin just moved, this is expected: record the new value with

    sed -n 's/.*SOURCE_HASH "\\(.*\\)"\$/\\1/p' <(python3 vendor/openQ4/tools/build/generate_savegame_compat_header.py \\
        --project-root vendor/openQ4 --game-stage-root vendor/openQ4-game --header-out /dev/stdout)

i.e. put $GOT into overlay/savegame-stamp.txt, and say in the OTA notes that
saves from earlier builds will not load.

If UPSTREAM.pin did NOT move, something is wrong and must not be papered over:
a dirty vendor tree (\`git -C vendor/openQ4 status\`, same for vendor/openQ4-game
— hand edits under vendor/ are forbidden by ground rule 1), a partial clone, or
a change to upstream's generator. Fix the cause, do not update the stamp.
EOF
	exit 1
fi

if [ -f "$HEADER" ] && cmp -s "$TMP" "$HEADER"; then
	rm -f "$TMP"
else
	mv "$TMP" "$HEADER"
fi

if [ "$PRINT_HASH" = 1 ]; then
	echo "$GOT"
else
	echo "    openq4_savegame_compat_generated.h  stamp ${GOT:0:12} ($COUNT files, from the pin, matches overlay/savegame-stamp.txt)"
fi
