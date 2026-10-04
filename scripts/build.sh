#!/usr/bin/env bash
# build.sh — one command from a fresh clone to a built openQ4.app (D-113).
#
#   scripts/build.sh [sim|device|visionos|visionos-sim] [--public]
#
# Runs, in order, every step the lane needs — each one idempotent and each one
# failing loudly:
#
#   fetch-vendor.sh            the pinned openQ4 + openQ4-game pair -> vendor/
#   build-baseoq4-paks.sh      openQ4's own runtime packs (skipped when the
#                              packs come from a macOS oracle build instead)
#   sync-overlay.sh            vendor + overlay patches -> build/src-ios
#   build-ios-deps.sh <lane>   SDL3, MoltenVK, OpenAL Soft (static)
#   build-ios-engine.sh <lane> the engine archive
#   build-ios-game-modules.sh <lane> both
#   build-ios-app.sh <lane> [--public]
#
# Default lane: sim (an unsigned iOS simulator build, no Apple account needed).
# --public builds the flavour a GitHub release ships, with the developer
# console bridge compiled out. Install and launch with scripts/sim-verify.sh.
#
# Requirements: see README.md "Building from source".

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LANE=sim
APP_ARGS=()
for a in "$@"; do
	case "$a" in
		sim|device|visionos|visionos-sim) LANE="$a" ;;
		--public) APP_ARGS+=( --public ) ;;
		-h|--help) sed -n '2,24p' "$0"; exit 0 ;;
		*) echo "usage: $0 [sim|device|visionos|visionos-sim] [--public]" >&2; exit 1 ;;
	esac
done

step() { echo; echo "######## $*"; }

for tool in git python3 cmake xcodegen xcodebuild xcrun rsync patch; do
	command -v "$tool" >/dev/null || { echo "FATAL: '$tool' not found — see README.md, Building from source" >&2; exit 1; }
done

step "1/7 vendor (pinned upstream pair)"
"$ROOT/scripts/fetch-vendor.sh"

step "2/7 baseoq4 runtime packs"
. "$ROOT/scripts/paks.sh"
if [ "$(openq4_paks_source)" = vendor ]; then
	"$ROOT/scripts/build-baseoq4-paks.sh"
else
	echo "==> using $(openq4_paks_source) packs at $(openq4_paks_dir)"
fi

step "3/7 overlay"
"$ROOT/scripts/sync-overlay.sh"

step "4/7 dependencies ($LANE)"
"$ROOT/scripts/build-ios-deps.sh" "$LANE"

step "5/7 engine ($LANE)"
"$ROOT/scripts/build-ios-engine.sh" "$LANE"

step "6/7 game modules ($LANE)"
"$ROOT/scripts/build-ios-game-modules.sh" "$LANE" both

step "7/7 app ($LANE ${APP_ARGS[*]:-})"
"$ROOT/scripts/build-ios-app.sh" "$LANE" ${APP_ARGS[@]+"${APP_ARGS[@]}"}
