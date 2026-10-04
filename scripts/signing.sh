#!/usr/bin/env bash
# signing.sh — load the Apple signing identifiers for a DEVICE build.
#
#   source "$ROOT/scripts/signing.sh"; openq4_load_signing [--need-asc]
#
# Values come from the environment first, then scripts/signing.local.sh (copy
# scripts/signing.local.sh.example and fill it in). Nothing here is needed for
# the simulator lanes, which build unsigned.
#
# After a successful call these are set and exported:
#   OPENQ4_TEAM_ID         Apple Developer team ID, passed as DEVELOPMENT_TEAM
#   OPENQ4_EXPORT_AUTH     array of -authenticationKey* arguments for
#                          `xcodebuild -exportArchive` (empty when no ASC key is
#                          configured — Xcode's signed-in account is used then)

openq4_load_signing() {
	local need_asc=0
	[ "${1:-}" = "--need-asc" ] && need_asc=1
	local here local_file
	here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local_file="$here/signing.local.sh"

	# Environment wins: remember what was set before sourcing the file.
	local env_team="${OPENQ4_TEAM_ID:-}" env_kid="${OPENQ4_ASC_KEY_ID:-}"
	local env_iss="${OPENQ4_ASC_ISSUER_ID:-}" env_kpath="${OPENQ4_ASC_KEY_PATH:-}"
	if [ -f "$local_file" ]; then
		# shellcheck disable=SC1090
		. "$local_file"
	fi
	[ -n "$env_team" ]  && OPENQ4_TEAM_ID="$env_team"
	[ -n "$env_kid" ]   && OPENQ4_ASC_KEY_ID="$env_kid"
	[ -n "$env_iss" ]   && OPENQ4_ASC_ISSUER_ID="$env_iss"
	[ -n "$env_kpath" ] && OPENQ4_ASC_KEY_PATH="$env_kpath"

	case "${OPENQ4_TEAM_ID:-}" in
		''|XXXXXXXXXX)
			echo "FATAL: no Apple team ID for a device build." >&2
			echo "       cp scripts/signing.local.sh.example scripts/signing.local.sh and fill it in," >&2
			echo "       or export OPENQ4_TEAM_ID=<your team id>." >&2
			return 1 ;;
	esac
	export OPENQ4_TEAM_ID

	OPENQ4_EXPORT_AUTH=()
	if [ -n "${OPENQ4_ASC_KEY_ID:-}" ] || [ -n "${OPENQ4_ASC_ISSUER_ID:-}" ] || [ -n "${OPENQ4_ASC_KEY_PATH:-}" ]; then
		[ -n "${OPENQ4_ASC_KEY_ID:-}" ] && [ -n "${OPENQ4_ASC_ISSUER_ID:-}" ] && [ -n "${OPENQ4_ASC_KEY_PATH:-}" ] || {
			echo "FATAL: the App Store Connect key is half-configured — set all of" >&2
			echo "       OPENQ4_ASC_KEY_ID, OPENQ4_ASC_ISSUER_ID and OPENQ4_ASC_KEY_PATH, or none." >&2
			return 1; }
		[ -f "$OPENQ4_ASC_KEY_PATH" ] || {
			echo "FATAL: App Store Connect key file not found: $OPENQ4_ASC_KEY_PATH" >&2
			return 1; }
		OPENQ4_EXPORT_AUTH=(
			-authenticationKeyPath "$OPENQ4_ASC_KEY_PATH"
			-authenticationKeyID "$OPENQ4_ASC_KEY_ID"
			-authenticationKeyIssuerID "$OPENQ4_ASC_ISSUER_ID"
		)
	elif [ "$need_asc" = 1 ]; then
		echo "FATAL: this step needs an App Store Connect API key (OPENQ4_ASC_*)." >&2
		return 1
	fi
	return 0
}
