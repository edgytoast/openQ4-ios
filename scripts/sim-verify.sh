#!/usr/bin/env bash
# sim-verify.sh — install openQ4 on the lane simulator, feed it game data, boot
# it, and collect evidence.
#
#   scripts/sim-verify.sh                    # install + launch + capture (iOS lane 1)
#   scripts/sim-verify.sh --lane visionos    # the same, on the Apple Vision Pro
#   scripts/sim-verify.sh --data             # also (re)stage game data first — slow, ~600 MB
#   scripts/sim-verify.sh --keep-booted
#
# Environment (D-113 — nothing here is specific to one machine any more):
#   SIM_APP          app bundle to install (default: the lane's build output;
#                    point it at build/sim-app-public/... for a public build)
#   SIM_UDID         simulator to use (default: looked up by SIM_NAME on the
#                    newest iOS / visionOS runtime — see the lane table below)
#   SIM_NAME         device name for that lookup
#   OPENQ4_GAMEDATA  folder that CONTAINS your retail q4base/ (for --data);
#                    default work/gamedata/Quake4
#
# Charter ground rule 6: a claim needs an artifact. This script produces a
# content screenshot and the engine's own log, or it fails.
#
# Lane rules: never create simulators, stay in our lane, and shut the
# device down at the end of EVERY run including a failed one.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID=com.rebelancap.openq4
ARTIFACTS="$ROOT/artifacts/sim"

STAGE_DATA=0
KEEP_BOOTED=0
LANE=sim
ENGINE_ARGS=()
while [ $# -gt 0 ]; do
	case "$1" in
		--data)        STAGE_DATA=1; shift ;;
		--keep-booted) KEEP_BOOTED=1; shift ;;
		--lane)        LANE="${2:-}"; shift 2 ;;
		--)            shift; ENGINE_ARGS=("$@"); break ;;
		*) echo "unknown argument: $1" >&2; exit 1 ;;
	esac
done

# Devices are addressed by UDID, not name, so a renamed or duplicated device can
# never silently redirect this into someone else's lane (D-004).
#
# ROTATE: before iOS 27, simctl captured the framebuffer in the device's NATURAL
# orientation, so a landscape app on a naturally-portrait iPhone photographed
# rotated 90 degrees. iOS 27 captures upright already (see ROTATE=auto below).
# A visionOS window is not a panel and has no natural orientation, so rotating
# its capture would be the bug rather than the fix.
case "$LANE" in
	sim)
		APP="${SIM_APP:-$ROOT/build/sim-app/Release-iphonesimulator/openQ4.app}"
		SIM_NAME="${SIM_NAME:-iPhone 17 Pro Max}"   # lane 1
		SIM_PLATFORM=iOS
		ROTATE=auto                       # resolved from the runtime below
		;;
	visionos)
		APP="${SIM_APP:-$ROOT/build/visionos-sim-app/Release-xrsimulator/openQ4.app}"
		# The program's ONLY visionOS device (D-004). Never cloned, never created.
		SIM_NAME="${SIM_NAME:-Apple Vision Pro}"
		SIM_PLATFORM=xrOS
		ROTATE=0
		;;
	*) echo "FATAL: unknown lane '$LANE' (sim|visionos)" >&2; exit 1 ;;
esac

# The device by UDID, resolved ONCE here from its name on the newest runtime of
# the lane's platform, so a renamed or duplicated device still cannot silently
# redirect a run (D-004) — and so no machine's UDIDs live in this script
# (D-113). SIM_UDID overrides the lookup. This script never creates a device.
if [ -z "${SIM_UDID:-}" ]; then
	SIM_UDID="$(xcrun simctl list devices available -j | python3 -c '
import json, re, sys
name, plat = sys.argv[1], sys.argv[2]
best = None
for rt, devs in json.load(sys.stdin)["devices"].items():
    m = re.search(r"SimRuntime\.%s-(\d+)-(\d+)" % plat, rt)
    if not m:
        continue
    ver = (int(m.group(1)), int(m.group(2)))
    for d in devs:
        if d["name"] == name and (best is None or ver > best[0]):
            best = (ver, d["udid"])
print(best[1] if best else "")
' "$SIM_NAME" "$SIM_PLATFORM")"
	[ -n "$SIM_UDID" ] || { echo "FATAL: no available '$SIM_NAME' simulator ($SIM_PLATFORM) — set SIM_UDID or SIM_NAME (this script never creates devices)" >&2; exit 1; }
fi
echo "==> lane $LANE: $SIM_NAME ($SIM_UDID)"

# iOS 27 changed the capture: `simctl io screenshot` now returns the frame in
# INTERFACE orientation (a landscape app comes back 2868x1320 on lane 1,
# publish-66), so the old natural-orientation fix-up rotated nothing for the
# game and turned any genuinely portrait frame (boot, home screen) sideways
# (D-112). Rotate only on runtimes older than 27.
if [ "$ROTATE" = "auto" ]; then
	SIM_RUNTIME="$(xcrun simctl list devices -j 2>/dev/null | python3 -c '
import json, sys
for rt, devs in json.load(sys.stdin)["devices"].items():
    for d in devs:
        if d["udid"] == sys.argv[1]:
            print(rt)
' "$SIM_UDID")"
	SIM_RUNTIME_MAJOR="$(printf '%s' "$SIM_RUNTIME" | sed -nE 's/.*iOS-([0-9]+)-.*/\1/p')"
	if [ -n "$SIM_RUNTIME_MAJOR" ] && [ "$SIM_RUNTIME_MAJOR" -lt 27 ]; then ROTATE=1; else ROTATE=0; fi
	echo "==> $SIM_NAME runtime ${SIM_RUNTIME:-unknown}: ROTATE=$ROTATE"
fi

fail() { echo "FATAL: $*" >&2; cleanup; exit 1; }

cleanup() {
	if [ "$KEEP_BOOTED" = "0" ]; then
		echo "==> shutting down $SIM_NAME"
		xcrun simctl shutdown "$SIM_UDID" 2>/dev/null || true
	else
		echo "==> leaving $SIM_NAME booted (--keep-booted)"
	fi
}
trap cleanup EXIT

case "$LANE" in
	sim)      BUILD_LANE=sim ;;
	visionos) BUILD_LANE=visionos-sim ;;
esac
[ -d "$APP" ] || fail "no app bundle — run scripts/build-ios-app.sh $BUILD_LANE first"
[ -f "$APP/openQ4" ] || fail "app bundle has no executable"
mkdir -p "$ARTIFACTS"

# Lane etiquette, enforced rather than remembered (lane rules): a simulator
# runs ONE foreground app, and launching ours on a device another session is
# testing backgrounds theirs mid-test — which tears down the Metal drawable and
# the audio session and produces failures that look like port bugs but are not.
# There is exactly one visionOS device in the program, so this is not theoretical
# there.
FOREIGN="$(xcrun simctl spawn "$SIM_UDID" launchctl list 2>/dev/null \
	| grep UIKitApplication | grep -v com.apple | grep -v "$BUNDLE_ID" || true)"
if [ -n "$FOREIGN" ]; then
	echo "!! another app is running on $SIM_NAME:" >&2
	echo "$FOREIGN" | sed 's/^/     /' >&2
	echo "   NOT launching. Install only; wait for the lane and retry." >&2
	xcrun simctl install "$SIM_UDID" "$APP" || true
	KEEP_BOOTED=1   # it is not ours to shut down
	exit 2
fi

echo "==> booting $SIM_NAME ($SIM_UDID)"
xcrun simctl boot "$SIM_UDID" 2>/dev/null || true
xcrun simctl bootstatus "$SIM_UDID" -b > /dev/null 2>&1 || fail "device did not finish booting"

echo "==> installing"
xcrun simctl install "$SIM_UDID" "$APP" || fail "install failed"

CONTAINER="$(xcrun simctl get_app_container "$SIM_UDID" "$BUNDLE_ID" data 2>/dev/null)"
[ -n "$CONTAINER" ] || fail "could not resolve the app data container"
DOCS="$CONTAINER/Documents"
mkdir -p "$DOCS"

if [ "$STAGE_DATA" = "1" ]; then
	# The engine needs BOTH its own baseoq4 packs (MD5-verified, hard fatal on
	# mismatch) and the user's retail q4base. Both are large; this is why data
	# staging is opt-in rather than every run.
	GAMEDATA="${OPENQ4_GAMEDATA:-$ROOT/work/gamedata/Quake4}"
	[ -d "$GAMEDATA/q4base" ] || fail "no retail game data at $GAMEDATA/q4base (set OPENQ4_GAMEDATA to the folder containing q4base/)"

	# baseoq4 ships inside the bundle (build-ios-app.sh stages it), so only the
	# user's retail data is staged here — into Documents/q4base, which is where
	# onboarding imports to and where fs_savepath now points on iOS. Staging
	# here is exactly what a real import produces, so this path is tested.
	SAVEPATH="$CONTAINER/Documents"
	echo "==> staging retail q4base (~2.6 GB) into $SAVEPATH"
	mkdir -p "$SAVEPATH/q4base"
	cp "$GAMEDATA/q4base/"*.pk4 "$SAVEPATH/q4base/" || fail "q4base copy failed"
fi

# simctl launch passes argv and it DOES reach the engine: overlay patch 0002
# stashes argv and hands it to common->Init(), so `-- +set <cvar> <value>` works
# (docs/mods.md proved it with `+set fs_game`). It is still a development
# channel only — a shipped app has no command line — so anything a player must
# be able to choose goes through the shell instead (the mod picker's
# `+set fs_game`, D-080). The engine's own user config, exec'd after
# default.cfg / openq4_defaults.cfg, is the other channel and the one used
# below for the simulator workarounds.
SIM_CFG_DIR="$CONTAINER/Library/Application Support/openQ4/baseoq4"
mkdir -p "$SIM_CFG_DIR"
{
	echo '// generated by scripts/sim-verify.sh — simulator workarounds only.'
	echo '// The iOS SIMULATOR GPU lacks features every real Apple GPU has;'
	echo '// none of these should ever be set on a device build.'
	echo ''
	echo '// No BC/DXT texture support on the simulator (the oracle measures'
	echo '// BC=1 on real Apple silicon). Retail Quake 4 is DDS/BC-heavy, so'
	echo '// without this the first BC1 upload aborts the process.'
	echo 'seta image_usePrecompressedTextures "0"'
	# Printed verbatim, NOT word-split: a cvar line is three words
	# (`seta name "value"`) and an unquoted for-loop would emit each of them
	# on a line of its own, producing a config the engine silently rejects.
	if [ -n "${SIM_EXTRA_CVARS:-}" ]; then printf '%s\n' "$SIM_EXTRA_CVARS"; fi
	# NOTE: a `map` command cannot go here. The user config is exec'd during
	# early init, long before the game module registers `map` — the engine
	# answers "Unknown command 'map'". Maps are driven over the console bridge
	# instead (SIM_BOOT_MAP below), which is exactly the "drive sequencing from
	# the shell or bridge" advice the charter inherited.
} > "$SIM_CFG_DIR/openQ4Config.cfg"
echo "==> wrote simulator config ($(wc -l < "$SIM_CFG_DIR/openQ4Config.cfg" | tr -d ' ') lines)"

echo "==> launching"
# MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0 is mandatory on the simulator: Metal
# argument buffers break every descriptor read there, producing a wholly black
# frame with NO error and no validation output. Devices are unaffected.
# SDL_JOYSTICK_MFI=0 stops the sim forwarding a controller paired to the Mac
# into the guest, which makes SDL open it and touch overlays hide themselves.
LAUNCH_LOG="$ARTIFACTS/launch.log"
SIMCTL_CHILD_MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0 \
SIMCTL_CHILD_SDL_JOYSTICK_MFI=0 \
SIMCTL_CHILD_OPENQ4_CONSOLE_BRIDGE=1 \
	xcrun simctl launch --console-pty "$SIM_UDID" "$BUNDLE_ID" \
		${ENGINE_ARGS[@]+"${ENGINE_ARGS[@]}"} > "$LAUNCH_LOG" 2>&1 &
LAUNCH_PID=$!

# Let the engine settle on a frame. Killing the --console-pty session SIGTERMs
# the app, so the screenshot MUST be taken while that session is still alive —
# capturing after the kill photographs the home screen and looks like the app
# never ran.
SETTLE="${SIM_SETTLE_SECONDS:-45}"
echo "==> letting the engine settle (${SETTLE}s)"
for _ in $(seq 1 "$SETTLE"); do
	sleep 1
	if ! kill -0 "$LAUNCH_PID" 2>/dev/null; then
		echo "   (launch session ended early — engine exited or crashed)"
		break
	fi
done

# Drive the engine into a map over the bridge once it is up. The charter is
# explicit that main-menu startup is not validation.
if [ -n "${SIM_BOOT_MAP:-}" ]; then
	# The bridge only starts listening after common->Init(), which includes
	# several seconds of media loading. Sending before then silently drops the
	# command — the run then looks like "the map never loaded" when in fact it
	# was never asked for.
	echo "==> waiting for the bridge to accept"
	READY=0
	for _ in $(seq 1 60); do
		if nc -z 127.0.0.1 8774 2>/dev/null; then READY=1; break; fi
		sleep 1
	done
	[ "$READY" = "1" ] || echo "!! bridge never came up on :8774" >&2

	echo "==> bridge: map ${SIM_BOOT_MAP}"
	"$ROOT/scripts/ios-console.sh" "map ${SIM_BOOT_MAP}" "${SIM_MAP_WAIT:-60}" \
		> "$ARTIFACTS/bridge.log" 2>&1 || echo "!! bridge command failed" >&2
	tail -5 "$ARTIFACTS/bridge.log" 2>/dev/null | sed 's/^/    /'

	# Liveness probe. If this round-trips, the display link is still calling
	# OpenQ4_iOS_BridgeDrain -> common->Frame(), i.e. the engine is advancing
	# frames rather than merely having finished a load and stalled. Without it a
	# stalled engine and a running one look identical in a screenshot.
	echo "==> bridge: liveness probe"
	"$ROOT/scripts/ios-console.sh" "echo OPENQ4_FRAME_LOOP_ALIVE" 6 \
		> "$ARTIFACTS/probe.log" 2>&1 || true
	if grep -q 'OPENQ4_FRAME_LOOP_ALIVE' "$ARTIFACTS/probe.log" 2>/dev/null; then
		echo "    frame loop ALIVE (command round-tripped after the map load)"
	else
		echo "    !! probe did not round-trip — engine may have stalled after load" >&2
	fi
fi

# Extra bridge commands, one per line, run after the map is up. This is how a
# round drives a feature that needs a gesture the simulator cannot deliver —
# `!touchtap 0.5 0.5` for in-world GUI touch (D-071) — and it keeps the driving
# in the script so the artifact is reproducible instead of hand-typed.
if [ -n "${SIM_BRIDGE_CMDS:-}" ]; then
	: > "$ARTIFACTS/bridge-extra.log"
	while IFS= read -r c; do
		[ -n "$c" ] || continue
		echo "==> bridge: $c"
		echo "--- $c" >> "$ARTIFACTS/bridge-extra.log"
		"$ROOT/scripts/ios-console.sh" "$c" "${SIM_BRIDGE_WAIT:-6}" \
			>> "$ARTIFACTS/bridge-extra.log" 2>&1 || echo "!! bridge command failed: $c" >&2
	done <<< "$SIM_BRIDGE_CMDS"
	tail -20 "$ARTIFACTS/bridge-extra.log" | sed 's/^/    /'
fi

# simctl captures the framebuffer in the device's NATURAL orientation, so a
# landscape app on a naturally-portrait device photographs rotated 90 degrees.
# That is a capture artifact, not a port bug — but it reads exactly like one, so
# every shot goes through here rather than leaving misleading PNGs in the repo.
shoot() { # <path>
	xcrun simctl io "$SIM_UDID" screenshot "$1" 2>/dev/null || { echo "!! screenshot failed: $1" >&2; return 1; }
	local sw sh
	sw="$(sips -g pixelWidth "$1" 2>/dev/null | awk '/pixelWidth/{print $2}')"
	sh="$(sips -g pixelHeight "$1" 2>/dev/null | awk '/pixelHeight/{print $2}')"
	if [ "$ROTATE" = "1" ] && [ -n "$sw" ] && [ -n "$sh" ] && [ "$sh" -gt "$sw" ]; then
		sips -r -90 "$1" --out "$1" >/dev/null 2>&1
	fi
	# "A claim needs an artifact" is only true if the artifact SHOWS something.
	# A uniform image is what a failed-to-render run produces — on the visionOS
	# simulator specifically, MoltenVK with Metal argument buffers left on
	# renders solid black with no error at all — and a solid black PNG in a
	# NOTES.md reads exactly like a dark game scene. Say which it is.
	python3 - "$1" <<'PY' || true
import sys
try:
    from PIL import Image
except Exception:
    sys.exit(0)
im = Image.open(sys.argv[1]).convert("RGB")
colours = im.getcolors(maxcolors=1 << 20)
if colours is None:
    print("    screenshot: many colours (content)")
else:
    if len(colours) == 1:
        print(f"    !! screenshot is UNIFORM {colours[0][1]} — BLANK, not content")
    else:
        print(f"    screenshot: {len(colours)} distinct colours")
PY
}

# SIM_SCRIPT — a driven run: bridge commands, waits and NAMED screenshots
# interleaved, in the order a round actually needs them. One line each:
#
#   c <command> [seconds]   send over the bridge, read replies for [seconds]
#   w <seconds>             wait
#   s <name>                screenshot to $ARTIFACTS/$SIM_SHOT_DIR/<name>.png
#   x <shell command>       run it on the HOST, output into the script log. This
#                           is how a round reaches things the bridge cannot —
#                           backgrounding the app (simctl launch of another
#                           app), reading NSUserDefaults out of the container —
#                           without the sequence living only in a transcript.
#
# Before/after evidence needs a shot BETWEEN two commands, which the single
# end-of-run capture cannot produce; rounds were hand-driving this instead, so
# the exact sequence behind a screenshot lived only in a NOTES.md transcript.
# Same notation those transcripts already used, now executable.
if [ -n "${SIM_SCRIPT:-}" ]; then
	SHOTDIR="$ARTIFACTS/${SIM_SHOT_DIR:-script}"
	mkdir -p "$SHOTDIR"
	SCRIPTLOG="$ARTIFACTS/${SIM_SHOT_DIR:-script}/bridge-script.log"
	: > "$SCRIPTLOG"
	while IFS= read -r line; do
		line="${line#"${line%%[![:space:]]*}"}"   # ltrim
		[ -n "$line" ] || continue
		case "$line" in
			\#*) continue ;;
			"c "*)
				body="${line#c }"
				# Trailing integer is the read timeout, not part of the command.
				secs="${body##* }"
				if [ "$secs" -eq "$secs" ] 2>/dev/null; then body="${body% *}"; else secs="${SIM_BRIDGE_WAIT:-6}"; fi
				echo "==> bridge: $body (${secs}s)"
				echo "--- c $body" >> "$SCRIPTLOG"
				"$ROOT/scripts/ios-console.sh" "$body" "$secs" >> "$SCRIPTLOG" 2>&1 \
					|| echo "!! bridge command failed: $body" >&2
				;;
			"w "*) echo "==> wait ${line#w }s"; sleep "${line#w }" ;;
			"x "*)
				body="${line#x }"
				echo "==> host: $body"
				echo "--- x $body" >> "$SCRIPTLOG"
				# Deliberately not `set -e`-fatal: a host step that fails is
				# evidence too, and killing the run here would strand a booted
				# device. SIM_UDID and SIM_NAME are exported for the command.
				SIM_UDID="$SIM_UDID" SIM_NAME="$SIM_NAME" \
					bash -c "$body" >> "$SCRIPTLOG" 2>&1 \
					|| echo "!! host command failed: $body" >&2
				;;
			"s "*)
				name="${line#s }"
				echo "==> shot: $name"
				echo "--- s $name" >> "$SCRIPTLOG"
				shoot "$SHOTDIR/$name.png"
				;;
			*) echo "!! SIM_SCRIPT: unrecognised line: $line" >&2; exit 1 ;;
		esac
	done <<< "$SIM_SCRIPT"
	echo "==> script shots in $SHOTDIR"
fi

echo "==> capturing"
SHOT="$ARTIFACTS/boot.png"
shoot "$SHOT"

# Only now tear the session down.
kill "$LAUNCH_PID" 2>/dev/null || true

# The launch beacon is written by a pre-main constructor, so its presence proves
# the process started even when the engine dies before any logging exists.
BEACON="$DOCS/launch-beacon.txt"
if [ -f "$BEACON" ]; then
	echo "==> launch beacon:"
	tail -3 "$BEACON" | sed 's/^/    /'
else
	echo "!! no launch beacon — the process did not reach main" >&2
fi

ENGINE_LOG="$DOCS/baseoq4/logs/openq4.log"
[ -f "$ENGINE_LOG" ] && cp "$ENGINE_LOG" "$ARTIFACTS/openq4.log"

echo
echo "==> launch output (tail):"
tail -25 "$LAUNCH_LOG" 2>/dev/null | sed 's/^/    /'
echo
echo "artifacts: $ARTIFACTS"
