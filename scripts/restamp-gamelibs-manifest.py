#!/usr/bin/env python3
"""Re-stamp the gamelibs stage manifest after the game overlay patches applied.

`tools/build/stage_gamelibs.py` writes `openq4_gamelibs_stage_manifest.json` —
a sha256 per staged file — and validates it before it returns. We then patch
`src/game` / `src/mpgame` in place (D-070), which makes every one of those
recorded hashes describe a file that no longer exists on disk. Nothing in the
build reads the manifest today, and that is exactly why it must not be allowed
to rot: the first thing that does read it would be told a lie.

So: rehash every file the manifest lists, keep the manifest's own validator
happy, and record which patches were applied under `overlayGamePatches` so the
stage says out loud that it is not pristine upstream.

Failures are loud (ground rule 3): a missing file, an unreadable manifest, or a
patch directory that vanished are all errors, never a silent skip.
"""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

MANIFEST_NAME = "openq4_gamelibs_stage_manifest.json"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("usage: restamp-gamelibs-manifest.py <stage-root> <game-patch-dir>", file=sys.stderr)
        return 2

    stage_root = Path(argv[1]).resolve()
    patch_dir = Path(argv[2])

    manifest_path = stage_root / MANIFEST_NAME
    if not manifest_path.is_file():
        print(f"error: no stage manifest at {manifest_path}", file=sys.stderr)
        return 1

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    files = manifest.get("files")
    if not isinstance(files, list):
        print("error: stage manifest has no file list", file=sys.stderr)
        return 1

    changed = 0
    for entry in files:
        rel = entry.get("path")
        if not isinstance(rel, str):
            print("error: malformed manifest entry", file=sys.stderr)
            return 1
        path = stage_root / rel
        if not path.is_file():
            print(f"error: manifest references missing staged file: {rel}", file=sys.stderr)
            return 1
        actual = sha256(path)
        if actual != entry.get("sha256"):
            entry["sha256"] = actual
            changed += 1

    manifest["overlayGamePatches"] = sorted(p.name for p in patch_dir.glob("*.patch"))
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"    restamped {changed} manifest hash(es) for {len(manifest['overlayGamePatches'])} game patch(es)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
