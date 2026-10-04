#!/usr/bin/env python3
"""make-app-icon.py — build the iOS app icon asset catalog from q4icon.ico.

    scripts/make-app-icon.py [source.ico]

Produces ios/Assets.xcassets with:

  AppIcon.appiconset      the app icon proper (single 1024 universal entry)
  AppIcon60x60.imageset   \\ standalone imagesets SideStore/AltStore need — see
  AppIcon76x76.imageset   / the note below

Two deliberate choices:

* **Black background, not transparency.** iOS app icons are composited on
  whatever is behind them and must be fully opaque; a transparent PNG renders
  with a black-or-white surprise depending on context. The Quake 4 mark is a
  glow on darkness, so black is also what it is designed to sit on.

* **The mark is inset.** In the source the glyph runs edge to edge vertically
  (alpha bbox 32,0..223,256), and iOS masks icons to a squircle, which would
  clip the tips. Insetting keeps the whole mark inside the mask.

The standalone AppIcon60x60 / AppIcon76x76 imagesets exist because SideStore and
AltStore render "My Apps" thumbnails with UIImage(named:) against the compiled
Assets.car by exact name. Without them the app shows a blank tile there while
looking perfectly fine on the Home Screen — and the simulator does not reproduce
it, because the simulator will happily read loose PNGs. (vkQuake-ios scar tissue.)
"""

import json
import pathlib
import sys

from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "q4icon.ico"
XCASSETS = ROOT / "ios" / "Assets.xcassets"

# Fraction of the canvas the artwork occupies. 0.84 clears the squircle mask
# while still reading as a full-bleed icon rather than a shrunken logo.
INSET_FRACTION = 0.84
MASTER = 1024


def load_largest_frame(path: pathlib.Path) -> Image.Image:
    im = Image.open(path)
    sizes = sorted(im.ico.sizes()) if hasattr(im, "ico") else [im.size]
    largest = max(sizes)
    frame = Image.open(path)
    frame.size = largest
    return frame.convert("RGBA")


def render(size: int, art: Image.Image) -> Image.Image:
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 255))
    target = max(1, int(round(size * INSET_FRACTION)))

    # Fit the artwork's non-transparent extent into the target box, preserving
    # aspect — the mark is taller than it is wide, so scaling by the long edge
    # is what keeps it from being clipped.
    bbox = art.getbbox() or (0, 0, art.width, art.height)
    cropped = art.crop(bbox)
    scale = min(target / cropped.width, target / cropped.height)
    new_size = (max(1, int(round(cropped.width * scale))),
                max(1, int(round(cropped.height * scale))))
    scaled = cropped.resize(new_size, Image.LANCZOS)

    canvas.alpha_composite(scaled, ((size - new_size[0]) // 2,
                                    (size - new_size[1]) // 2))
    return canvas.convert("RGB")


def write_imageset(directory: pathlib.Path, filename: str, image: Image.Image,
                   scales=("1x", "2x", "3x")) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    image.save(directory / filename)
    contents = {
        "images": [{"idiom": "universal", "filename": filename, "scale": s} for s in scales],
        "info": {"author": "xcode", "version": 1},
    }
    # Only the first scale carries the file; the others are declared empty so
    # actool does not complain about unassigned children.
    for entry in contents["images"][1:]:
        entry.pop("filename")
    (directory / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


def main() -> int:
    if not SRC.is_file():
        print(f"FATAL: no icon source at {SRC}", file=sys.stderr)
        return 1

    art = load_largest_frame(SRC)
    print(f"source: {SRC.name}  largest frame {art.size}")

    XCASSETS.mkdir(parents=True, exist_ok=True)
    (XCASSETS / "Contents.json").write_text(
        json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")

    # App icon: one 1024 universal entry (the modern single-size form).
    appicon = XCASSETS / "AppIcon.appiconset"
    appicon.mkdir(parents=True, exist_ok=True)
    render(MASTER, art).save(appicon / "AppIcon1024.png")
    (appicon / "Contents.json").write_text(json.dumps({
        "images": [{"filename": "AppIcon1024.png", "idiom": "universal",
                    "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "xcode", "version": 1},
    }, indent=2) + "\n")
    print(f"  AppIcon.appiconset      1024x1024")

    # Standalone imagesets for the sideload stores (see module docstring).
    for pt, px in (("60x60", 180), ("76x76", 152)):
        name = f"AppIcon{pt}"
        write_imageset(XCASSETS / f"{name}.imageset", f"{name}.png",
                       render(px, art), scales=("1x",))
        print(f"  {name}.imageset   {px}x{px}")

    print(f"\nwrote {XCASSETS}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
