#!/usr/bin/env bash
# check-public-binary.sh — prove what a linked openQ4 binary does and does not
# contain of the developer surface (D-113).
#
#   scripts/check-public-binary.sh <openQ4 executable> <public|dev> [lane]
#
# public: NONE of the bridge's code or strings may be present — the TCP
#         listener, its output tee, the `!` shell commands, the
#         openq4://console/ route and the onboarding test levers.
# dev:    ALL of the markers must be present, so the check cannot pass
#         vacuously (e.g. on a binary the strings moved out of).
#
# Markers are the things that would let someone outside the app reach the
# engine console: the listener's own symbols and banner, the lever and
# environment-variable names, and the `!` command words. The port number is a
# code immediate, not a string, so it is covered by the listener symbol and its
# "listening on" banner rather than by grepping for 8774.
#
# Run by build-ios-app.sh on every lane and by release.sh on every archive.

set -euo pipefail

BIN="${1:-}"; FLAVOUR="${2:-}"; LANE="${3:-}"
[ -f "$BIN" ] || { echo "usage: $0 <executable> <public|dev> [lane]" >&2; exit 2; }
case "$FLAVOUR" in public|dev) ;; *) echo "FATAL: flavour must be public or dev" >&2; exit 2 ;; esac

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
# To files first: `nm | grep -q` lets grep's early exit SIGPIPE nm, which
# pipefail turns into a race-dependent false failure (see build-ios-app.sh).
nm -a "$BIN" > "$TMPD/nm" 2>/dev/null
awk '{print $NF}' "$TMPD/nm" | sort -u > "$TMPD/syms"
strings -a "$BIN" > "$TMPD/strings" 2>/dev/null
[ "$(wc -l < "$TMPD/nm")" -gt 10000 ] \
	|| { echo "FATAL: $BIN has almost no symbols — stripped? (the MoltenVK dlsym needs them)" >&2; exit 1; }

# PUBLIC: any match of these is a failure. Symbol names include the static
# functions' block_invoke helpers, which survive inlining of their parent.
BAD_SYMBOLS='_Bridge(ListenThread|OutputThread|InstallOutputTee|HandleLocalCommand|WriteToClient)|_OpenQ4_(PrintViewHierarchy|DumpViewTree)'
BAD_STRINGS="openQ4 bridge|console bridge|OPENQ4_CONSOLE_BRIDGE|OPENQ4_BRIDGE_PORT|OPENQ4_ONBOARDING_(IMPORT|STOP_BEFORE_COMMIT|AUTOCHECK)|REFUSED console|usage: !|bridge's !|connect/ console/"

# DEV: each of these must be present, so the public check cannot pass
# vacuously. Chosen to survive optimisation: an address-taken thread entry
# (never inlined) and printf/getenv strings (short strcmp literals like
# "!framelink" are folded into immediates and do NOT survive as strings).
REQ_SYMBOLS=( _BridgeListenThread _BridgeOutputThread )
REQ_STRINGS=(
	"openQ4 console bridge ready"
	"openQ4 bridge: listening on"
	"OPENQ4_CONSOLE_BRIDGE"
	"OPENQ4_BRIDGE_PORT"
	"OPENQ4_ONBOARDING_IMPORT"
	"OPENQ4_ONBOARDING_STOP_BEFORE_COMMIT"
	"OPENQ4_ONBOARDING_AUTOCHECK"
	"REFUSED console"
	"openQ4 bridge: usage: !touchtap"
	"openQ4 bridge: unknown local command"
)

# visionOS: the target's own defines must survive the public flag's
# $(inherited) — the 3D mode is not a developer surface.
if [ "$LANE" = visionos ] || [ "$LANE" = visionos-sim ]; then
	grep -q ' _OpenQ4_Vision3D_Set$' "$TMPD/nm" \
		|| { echo "FATAL: visionOS binary lacks _OpenQ4_Vision3D_Set — the target's OPENQ4_VISIONOS_3D define was lost" >&2; exit 1; }
fi

if [ "$FLAVOUR" = public ]; then
	bad_s="$(grep -E "^($BAD_SYMBOLS)" "$TMPD/syms" || true)"
	bad_t="$(grep -E -- "$BAD_STRINGS" "$TMPD/strings" | sort -u || true)"
	if [ -n "$bad_s$bad_t" ]; then
		echo "FATAL: PUBLIC binary still carries developer-surface markers:" >&2
		[ -z "$bad_s" ] || printf '  symbol %s\n' $bad_s >&2
		[ -z "$bad_t" ] || printf '%s\n' "$bad_t" | sed 's/^/  string: /' >&2
		exit 1
	fi
	echo "==> public surface check: no bridge symbols, no bridge/lever strings ($(basename "$BIN"))"
else
	missing=""
	for sym in "${REQ_SYMBOLS[@]}"; do
		grep -qx -- "$sym" "$TMPD/syms" || missing+="  symbol $sym"$'\n'
	done
	for str in "${REQ_STRINGS[@]}"; do
		grep -qF -- "$str" "$TMPD/strings" || missing+="  string '$str'"$'\n'
	done
	if [ -n "$missing" ]; then
		echo "FATAL: DEV binary is missing bridge markers — the check is stale or the bridge is gone:" >&2
		printf '%s' "$missing" >&2
		exit 1
	fi
	echo "==> dev surface check: bridge listener + ${#REQ_STRINGS[@]} lever/command strings present ($(basename "$BIN"))"
fi
