#!/usr/bin/env python3
"""make-visionos-app-icon.py — build the visionOS app icon from q4icon.ico.

    scripts/make-visionos-app-icon.py [source.ico]

Produces ios/Assets-visionos.xcassets with a single AppIcon.solidimagestack.

Why a separate script and a separate catalog (D-090):

* **visionOS icons are LAYERED, not flat.** The Home View renders an app icon as
  a stack of parallax layers inside a circular mask, and actool rejects an
  `.appiconset` for the `vision` idiom outright ("A Vision app icon must be a
  layer stack"). So the iOS catalog cannot be reused, and the iOS target's
  catalog is not touched by this.

* **Three layers (D-092; D-090 shipped two).** The mark is a black glyph
  with a green halo on a black ground. With Back = black and Front = glyph +
  halo together, the parallax was invisible on hardware: a black glyph moving
  over black shows nothing, and the halo moved WITH the glyph, so there was no
  edge for the eye to catch. The maintainer's verdict: "the Q should be a layer so it
  pops when you gaze at it." So the halo and the glyph are now split apart:
  Back = opaque black ground, Middle = the green halo with the glyph's own
  footprint filled in (so the Front layer never reveals a hole when it shifts),
  Front = the black glyph alone. Gazing at the icon now slides a black Q over a
  bright green Q-shaped halo, which is exactly the depth the artwork implies.

* **The mask is a CIRCLE, not iOS's squircle**, and it crops harder. The inset
  here is tighter than the iOS script's 0.84 for that reason.

Layer images are 1024x1024 at the `vision` idiom's 2x scale, which is the size
actool wants for a solid image stack.
"""

import json
import pathlib
import sys

import numpy as np
from PIL import Image, ImageFilter

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "q4icon.ico"
XCASSETS = ROOT / "ios" / "Assets-visionos.xcassets"

# Tighter than the iOS 0.84: the visionOS mask is a full circle, so the corners
# are gone entirely and a mark sized for a squircle loses its tips.
INSET_FRACTION = 0.68
MASTER = 1024
INFO = {"author": "xcode", "version": 1}


def load_largest_frame(path: pathlib.Path) -> Image.Image:
    im = Image.open(path)
    sizes = sorted(im.ico.sizes()) if hasattr(im, "ico") else [im.size]
    largest = max(sizes)
    frame = Image.open(path)
    frame.size = largest
    return frame.convert("RGBA")


def fit_art(size: int, art: Image.Image) -> Image.Image:
    """The whole mark, centred and scaled to the inset, on transparency."""
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    target = max(1, int(round(size * INSET_FRACTION)))
    bbox = art.getbbox() or (0, 0, art.width, art.height)
    cropped = art.crop(bbox)
    scale = min(target / cropped.width, target / cropped.height)
    new_size = (max(1, int(round(cropped.width * scale))),
                max(1, int(round(cropped.height * scale))))
    scaled = cropped.resize(new_size, Image.LANCZOS)
    canvas.alpha_composite(scaled, ((size - new_size[0]) // 2,
                                    (size - new_size[1]) // 2))
    return canvas


# A source pixel is "glyph" when it is dark. The ico's mark is near-black
# (max channel well under 70) and its halo is saturated green (max channel
# above 150), so a soft ramp between the two separates them without a hard
# edge. Values are the max channel at which the ramp starts / ends.
GLYPH_DARK = 60
GLYPH_LIGHT = 140


def split_layers(size: int, art: Image.Image):
    """Split the fitted mark into (front glyph, middle halo) layers."""
    whole = np.asarray(fit_art(size, art), dtype=np.float32) / 255.0
    rgb, alpha = whole[..., :3], whole[..., 3]
    brightness = rgb.max(axis=-1)
    # 1.0 where the pixel is glyph-dark, 0.0 where it is halo-bright.
    glyphness = np.clip((GLYPH_LIGHT - brightness * 255.0) / (GLYPH_LIGHT - GLYPH_DARK), 0.0, 1.0)
    glyph_alpha = alpha * glyphness

    # Front: the glyph on transparency, black. Keep its anti-aliased edge.
    front = np.zeros_like(whole)
    front[..., 3] = glyph_alpha
    front_img = Image.fromarray((front * 255.0 + 0.5).astype(np.uint8), "RGBA")

    # Middle: the halo alone, then fill the glyph's footprint so a shifted
    # Front never uncovers a hole. The fill is the halo blurred inward: a
    # premultiplied blur of the halo-only layer, applied only under the glyph
    # and boosted to full coverage there, so the interior reads as the same
    # green the halo has at the glyph's edge (its brightest point).
    halo_alpha = alpha * (1.0 - glyphness)
    halo = np.dstack([rgb * halo_alpha[..., None], halo_alpha])   # premultiplied
    halo_img = Image.fromarray((halo * 255.0 + 0.5).astype(np.uint8), "RGBA")
    blur_radius = max(2, size // 64)
    filled = halo_img
    for _ in range(6):   # repeated blur+max walks the halo inward past the glyph's width
        blurred = np.asarray(filled.filter(ImageFilter.GaussianBlur(blur_radius)), dtype=np.float32) / 255.0
        cur = np.asarray(filled, dtype=np.float32) / 255.0
        filled = Image.fromarray((np.maximum(cur, blurred) * 255.0 + 0.5).astype(np.uint8), "RGBA")
    grown = np.asarray(filled, dtype=np.float32) / 255.0
    # Un-premultiply the grown halo and force full coverage under the glyph.
    ga = np.maximum(grown[..., 3], 1e-4)
    grown_rgb = np.clip(grown[..., :3] / ga[..., None], 0.0, 1.0)
    under = np.dstack([grown_rgb, np.ones_like(ga)])
    halo_straight = np.dstack([rgb, halo_alpha])
    mix = glyph_alpha[..., None]
    middle = halo_straight * (1.0 - mix) + under * mix
    # Outside the mark entirely, stay transparent.
    middle[..., 3] = np.where(alpha > 0.002, middle[..., 3], 0.0)
    middle_img = Image.fromarray((np.clip(middle, 0, 1) * 255.0 + 0.5).astype(np.uint8), "RGBA")
    return front_img, middle_img


def back_layer(size: int) -> Image.Image:
    """Opaque ground. The back layer of a stack must be fully opaque — a
    transparent one shows the system's placeholder through it."""
    return Image.new("RGBA", (size, size), (0, 0, 0, 255))


def write_layer(stack: pathlib.Path, name: str, image: Image.Image) -> None:
    layer = stack / f"{name}.solidimagestacklayer"
    content = layer / "Content.imageset"
    content.mkdir(parents=True, exist_ok=True)
    image.save(content / f"{name}.png")
    (content / "Contents.json").write_text(json.dumps({
        "images": [{"idiom": "vision", "filename": f"{name}.png", "scale": "2x"}],
        "info": INFO,
    }, indent=2) + "\n")
    (layer / "Contents.json").write_text(json.dumps({"info": INFO}, indent=2) + "\n")


def main() -> int:
    if not SRC.is_file():
        print(f"FATAL: no icon source at {SRC}", file=sys.stderr)
        return 1

    art = load_largest_frame(SRC)
    print(f"source: {SRC.name}  largest frame {art.size}")

    XCASSETS.mkdir(parents=True, exist_ok=True)
    (XCASSETS / "Contents.json").write_text(json.dumps({"info": INFO}, indent=2) + "\n")

    stack = XCASSETS / "AppIcon.solidimagestack"
    stack.mkdir(parents=True, exist_ok=True)
    front, middle = split_layers(MASTER, art)
    write_layer(stack, "Back", back_layer(MASTER))
    write_layer(stack, "Middle", middle)
    write_layer(stack, "Front", front)
    # Order is FRONT FIRST, back LAST. actool reads the list front-to-back, and
    # it enforces that the LAST layer with content is fully opaque:
    #   "The last visionOS App Icon Layer with content, 'Front', must be a fully
    #    opaque bitmap. The pixel at position (0, 0) has an alpha value of 0."
    # which is what listing Back first produces. The opaque ground goes last.
    (stack / "Contents.json").write_text(json.dumps({
        "layers": [{"filename": "Front.solidimagestacklayer"},
                   {"filename": "Middle.solidimagestacklayer"},
                   {"filename": "Back.solidimagestacklayer"}],
        "info": INFO,
    }, indent=2) + "\n")

    print(f"  AppIcon.solidimagestack  Back + Middle + Front, {MASTER}x{MASTER} @2x")
    print(f"\nwrote {XCASSETS}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
