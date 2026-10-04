#!/usr/bin/env bash
# build-baseoq4-paks.sh — build openQ4's baseoq4 runtime packs from the pinned
# vendor/openQ4 content, without meson and without the macOS oracle (D-113).
#
#   scripts/build-baseoq4-paks.sh            # -> build/baseoq4/{pak0.pk4,pak1.pk4,mod.json}
#   scripts/build-baseoq4-paks.sh --force    # rebuild even when the stamp matches
#
# This is the same work upstream's meson.build does for these three files
# (content/baseoq4/meson.build + the openq4_pak0/openq4_pak1 custom targets),
# done by calling the same Python tools directly:
#
#   write_pak_manifest.py   source manifest for each pack
#   build_openq4_pack.py    the pack itself (deterministic zip: fixed
#                           timestamps, so the MD5 is a function of content)
#   openq4_version.py       base_version, substituted into mod.json.in
#
# Needs only python3 (the system one is fine) and the vendor tree. pak1 is
# ~640 MB and takes a minute or two; the result is stamped with the pin commit
# and skipped next time unless the pin moves.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/vendor/openQ4"
OUT="$ROOT/build/baseoq4"
TOOLS="$VENDOR/tools/build"
STAMP="$OUT/.pin-commit"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

[ -d "$VENDOR/content/baseoq4/pak0" ] && [ -d "$VENDOR/content/baseoq4/pak1" ] \
	|| { echo "FATAL: no pack sources under $VENDOR/content/baseoq4 — run scripts/fetch-vendor.sh" >&2; exit 1; }
[ -f "$TOOLS/build_openq4_pack.py" ] || { echo "FATAL: $TOOLS/build_openq4_pack.py missing" >&2; exit 1; }

PIN_COMMIT="$(sed -n 's/^OPENQ4_COMMIT=//p' "$ROOT/UPSTREAM.pin" | head -1)"
HAVE_COMMIT="$(git -C "$VENDOR" rev-parse HEAD 2>/dev/null || true)"
[ -n "$PIN_COMMIT" ] && [ "$HAVE_COMMIT" = "$PIN_COMMIT" ] || {
	echo "FATAL: vendor/openQ4 is at ${HAVE_COMMIT:-<none>}, UPSTREAM.pin says $PIN_COMMIT" >&2
	echo "       run scripts/fetch-vendor.sh" >&2; exit 1; }
# vendor/ is never hand-edited (charter ground rule 1); a dirty content tree
# would make packs whose MD5s nobody else can reproduce.
if [ -n "$(git -C "$VENDOR" status --porcelain --untracked-files=no -- content)" ]; then
	echo "FATAL: vendor/openQ4/content has local modifications:" >&2
	git -C "$VENDOR" status --short --untracked-files=no -- content | head >&2
	exit 1
fi

if [ "$FORCE" = 0 ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$PIN_COMMIT" ] \
	&& [ -f "$OUT/pak0.pk4" ] && [ -f "$OUT/pak1.pk4" ] && [ -f "$OUT/mod.json" ]; then
	echo "==> baseoq4 packs already built for pin ${PIN_COMMIT:0:8} ($OUT)"
	exit 0
fi

mkdir -p "$OUT"
rm -f "$STAMP"
export PYTHONDONTWRITEBYTECODE=1   # keep __pycache__ out of vendor/

for pak in pak0 pak1; do
	echo "==> building $pak.pk4"
	python3 "$TOOLS/write_pak_manifest.py" "$VENDOR" "$pak.pk4" "content/baseoq4/$pak" "$OUT/.$pak.sources" \
		|| { echo "FATAL: $pak source manifest failed" >&2; exit 1; }
	python3 "$TOOLS/build_openq4_pack.py" --pak-name "$pak.pk4" \
		--source-dir "$VENDOR/content/baseoq4/$pak" \
		--manifest "$OUT/.$pak.sources" \
		--out "$OUT/$pak.pk4" \
		|| { echo "FATAL: $pak.pk4 build failed" >&2; exit 1; }
	[ -s "$OUT/$pak.pk4" ] || { echo "FATAL: $pak.pk4 is empty or missing" >&2; exit 1; }
done

echo "==> writing mod.json"
BASE_VERSION="$(python3 "$TOOLS/openq4_version.py" --source-root "$VENDOR" --track dev \
	| sed -n 's/^base_version=//p')"
[[ "$BASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
	|| { echo "FATAL: could not read base_version from openq4_version.py (got '$BASE_VERSION')" >&2; exit 1; }
n="$(grep -c '@OPENQ4_VERSION_BASE@' "$VENDOR/content/baseoq4/mod.json.in")"
[ "$n" = 2 ] || { echo "FATAL: expected 2 @OPENQ4_VERSION_BASE@ in mod.json.in, found $n" >&2; exit 1; }
sed "s/@OPENQ4_VERSION_BASE@/$BASE_VERSION/g" "$VENDOR/content/baseoq4/mod.json.in" > "$OUT/mod.json"

echo "$PIN_COMMIT" > "$STAMP"
echo
echo "PAKS OK (pin ${PIN_COMMIT:0:8}, base version $BASE_VERSION)"
ls -l "$OUT"/pak0.pk4 "$OUT"/pak1.pk4 "$OUT"/mod.json | awk '{print "  " $5 "\t" $9}'
md5 -q "$OUT/pak0.pk4" | sed 's/^/  pak0 md5 /'
md5 -q "$OUT/pak1.pk4" | sed 's/^/  pak1 md5 /'
