#!/usr/bin/env bash
# ios-console.sh — talk to the running openQ4 build's console bridge (:8774).
#
#   scripts/ios-console.sh                     # interactive
#   scripts/ios-console.sh "map mp/q4dm2"      # one-shot, prints the reply
#   scripts/ios-console.sh "map mp/q4dm2" 40   # one-shot, read replies for 40s
#
# The simulator shares the Mac's loopback, so this reaches a simulator build
# with no extra plumbing. A device build needs the phone on the tailnet.
set -uo pipefail
HOST="${OPENQ4_BRIDGE_HOST:-127.0.0.1}"
PORT="${OPENQ4_BRIDGE_PORT:-8774}"

if [ $# -eq 0 ]; then
	echo "== interactive console on $HOST:$PORT (ctrl-c to exit)"
	exec nc "$HOST" "$PORT"
fi

CMD="$1"
WAIT="${2:-5}"

# Fail loudly on a closed port. nc exits 0 with no output when it cannot
# connect through a pipe, so a command sent to a dead bridge used to look
# exactly like a command that worked and printed nothing — which is how a
# screenshot of an unchanged screen got taken as evidence.
if ! nc -z -G 2 "$HOST" "$PORT" 2>/dev/null; then
	echo "FATAL: nothing is listening on $HOST:$PORT" >&2
	echo "  the bridge is opt-in: launch with OPENQ4_CONSOLE_BRIDGE=1" >&2
	echo "  (simctl: SIMCTL_CHILD_OPENQ4_CONSOLE_BRIDGE=1 xcrun simctl launch ...)" >&2
	exit 1
fi

{ printf '%s\n' "$CMD"; sleep "$WAIT"; } | nc "$HOST" "$PORT"
