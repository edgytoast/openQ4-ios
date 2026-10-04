#!/usr/bin/env bash
# symbolicate.sh — turn a black-box STALL BACKTRACE into function names.
#
#   scripts/symbolicate.sh <version> <load-address> <addr> [addr...]
#   scripts/symbolicate.sh 0.1.0.11 0x104b70000 0x104b7c5d4 0x1048f1234
#
# The black box writes raw return addresses because a signal/watchdog context is
# no place to symbolicate. The binary they refer to is kept per published
# version by publish-ota.sh; this pairs the two.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

VERSION="${1:-}"; LOADADDR="${2:-}"; shift 2 || true
[ -n "$VERSION" ] && [ -n "$LOADADDR" ] && [ $# -gt 0 ] \
	|| { echo "usage: $0 <version> <load-address> <addr>..." >&2; exit 1; }

BIN="$ROOT/build/symbols/$VERSION/openQ4"
[ -f "$BIN" ] || { echo "FATAL: no archived binary for $VERSION at $BIN" >&2; exit 1; }

echo "== $VERSION ($(cat "$ROOT/build/symbols/$VERSION/build-id.txt" 2>/dev/null || echo '?')) =="
xcrun atos -o "$BIN" -arch arm64 -l "$LOADADDR" "$@"
