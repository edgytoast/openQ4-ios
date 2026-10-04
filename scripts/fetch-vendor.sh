#!/usr/bin/env bash
# fetch-vendor.sh — clone the two pinned upstreams into vendor/ (D-113).
#
#   scripts/fetch-vendor.sh
#
# vendor/openQ4       themuffinator/openQ4       at OPENQ4_REF / OPENQ4_COMMIT
# vendor/openQ4-game  themuffinator/openQ4-game  at OPENQ4_GAME_COMMIT
#
# Both come from UPSTREAM.pin and are pinned AS A PAIR (the game API version
# couples them). Shallow (--depth 1): the build needs no upstream history, and
# the engine clone is ~3 GB even so — 2.4 GB of it is content/, the source of
# the baseoq4 packs.
#
# Idempotent. An existing checkout is verified, not touched: if it sits at a
# different commit this fails and points at scripts/bump-pin.sh, which is the
# only thing allowed to move a pin. vendor/ is never hand-edited.
#
# The other three vendored dependencies (SDL3, OpenAL Soft, MoltenVK) are
# fetched by scripts/build-ios-deps.sh at their own pinned versions.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIN="$ROOT/UPSTREAM.pin"
[ -f "$PIN" ] || { echo "FATAL: missing $PIN" >&2; exit 1; }
pinval() { sed -n "s/^$1=//p" "$PIN" | head -1; }

ENGINE_REPO="$(pinval OPENQ4_REPO)"
ENGINE_REF="$(pinval OPENQ4_REF)"
ENGINE_COMMIT="$(pinval OPENQ4_COMMIT)"
GAME_REPO="$(pinval OPENQ4_GAME_REPO)"
GAME_COMMIT="$(pinval OPENQ4_GAME_COMMIT)"
for v in ENGINE_REPO ENGINE_COMMIT GAME_REPO GAME_COMMIT; do
	[ -n "${!v}" ] || { echo "FATAL: $v missing from $PIN" >&2; exit 1; }
done
command -v git >/dev/null || { echo "FATAL: git not found" >&2; exit 1; }

mkdir -p "$ROOT/vendor"

verify() { # <dir> <commit>
	local have
	have="$(git -C "$1" rev-parse HEAD 2>/dev/null || true)"
	[ "$have" = "$2" ] || {
		echo "FATAL: $1 is at ${have:-<not a git checkout>}, UPSTREAM.pin says $2" >&2
		echo "       move pins only with scripts/bump-pin.sh; to start over, delete $1 and re-run" >&2
		exit 1; }
}

# --- engine -------------------------------------------------------------------
E="$ROOT/vendor/openQ4"
if [ ! -d "$E" ]; then
	if [ -n "$ENGINE_REF" ]; then
		echo "==> cloning openQ4 $ENGINE_REF (shallow; ~3 GB, most of it pack content)"
		# --branch with a tag keeps the tag name locally: upstream's version
		# script reads it (git describe) for the engine's version banner.
		git -c advice.detachedHead=false clone --depth 1 --branch "$ENGINE_REF" "$ENGINE_REPO" "$E"
	else
		echo "==> cloning openQ4 at $ENGINE_COMMIT (shallow)"
		git init -q "$E"
		git -C "$E" remote add origin "$ENGINE_REPO"
		git -C "$E" fetch --depth 1 origin "$ENGINE_COMMIT"
		git -C "$E" -c advice.detachedHead=false checkout --quiet --detach FETCH_HEAD
	fi
fi
verify "$E" "$ENGINE_COMMIT"
echo "    vendor/openQ4       ${ENGINE_COMMIT:0:12} ${ENGINE_REF:+($ENGINE_REF)}"

# --- game modules (no tags upstream: fetch the commit) --------------------------
G="$ROOT/vendor/openQ4-game"
if [ ! -d "$G" ]; then
	echo "==> cloning openQ4-game at $GAME_COMMIT (shallow)"
	git init -q "$G"
	git -C "$G" remote add origin "$GAME_REPO"
	git -C "$G" fetch --depth 1 origin "$GAME_COMMIT"
	git -C "$G" -c advice.detachedHead=false checkout --quiet --detach FETCH_HEAD
fi
verify "$G" "$GAME_COMMIT"
echo "    vendor/openQ4-game  ${GAME_COMMIT:0:12}"

for d in "$E" "$G"; do
	if [ -n "$(git -C "$d" status --porcelain --untracked-files=no)" ]; then
		echo "FATAL: $d has local modifications — vendor/ is never hand-edited" >&2
		git -C "$d" status --short --untracked-files=no | head >&2
		exit 1
	fi
done
echo "VENDOR OK"
