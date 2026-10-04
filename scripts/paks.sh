#!/usr/bin/env bash
# paks.sh — where this build takes openQ4's own baseoq4 runtime packs from.
#
#   source "$ROOT/scripts/paks.sh"; PAKS="$(openq4_paks_dir)"
#
# The app ships pak0.pk4 + pak1.pk4 + mod.json inside its bundle, and the
# engine hard-fatals at startup unless their MD5s match the ones compiled into
# it (openq4_paks_generated.h, written by sync-overlay.sh FROM THE SAME FILES).
# So there must be exactly one answer to "which packs", shared by every script
# that touches them (sync-overlay.sh, stage-bundle-content.sh, publish-ota.sh,
# release.sh). This is that answer:
#
#   1. $OPENQ4_PAKS_DIR, when set — an explicit choice always wins.
#   2. the macOS oracle's meson output, work/oracle/openQ4/builddir/baseoq4,
#      when it exists (the original dev machine's path; D-110 keeps the oracle
#      at the pin, and sync-overlay.sh refuses it otherwise).
#   3. build/baseoq4, produced by scripts/build-baseoq4-paks.sh straight from
#      the pinned vendor/openQ4 content with upstream's own Python pack tools
#      (D-113) — the clean-machine path, no meson or oracle needed.
#
# Upstream's pack writer is deterministic (fixed zip timestamps, sorted
# entries), so (2) and (3) produce byte-identical pak0/pak1 at the same pin.

openq4_paks_dir() {
	local root
	root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
	if [ -n "${OPENQ4_PAKS_DIR:-}" ]; then
		echo "$OPENQ4_PAKS_DIR"
	elif [ -f "$root/work/oracle/openQ4/builddir/baseoq4/pak0.pk4" ]; then
		echo "$root/work/oracle/openQ4/builddir/baseoq4"
	else
		echo "$root/build/baseoq4"
	fi
}

# "oracle" | "vendor" | "explicit" — which rule above picked the directory.
openq4_paks_source() {
	local root
	root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
	if [ -n "${OPENQ4_PAKS_DIR:-}" ]; then
		echo explicit
	elif [ -f "$root/work/oracle/openQ4/builddir/baseoq4/pak0.pk4" ]; then
		echo oracle
	else
		echo vendor
	fi
}
