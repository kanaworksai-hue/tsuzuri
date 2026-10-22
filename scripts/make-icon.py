# /// script
# dependencies = ["pillow"]
# ///
"""Turns full-bleed square artwork into Resources/AppIcon.icns.

Applies the macOS icon grid (824 pt squircle body on a 1024 canvas, soft drop
shadow), then renders every iconset size and runs iconutil.

    uv run scripts/make-icon.py Resources/AppIcon-source.png
"""
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

CANVAS = 1024
BODY = 824
SUPERSAMPLE = 4


def squircle_mask(size: int, exponent: float = 5.0) -> Image.Image:
    """Superellipse |x|^n + |y|^n = 1, close to Apple's continuous-corner shape."""
    big = size * SUPERSAMPLE
    r = big / 2
    points = []
    steps = 2000
    import math
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        x = r + r * math.copysign(abs(c) ** (2 / exponent), c)
        y = r + r * math.copysign(abs(s) ** (2 / exponent), s)
        points.append((x, y))
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).polygon(points, fill=255)
    return mask.resize((size, size), Image.LANCZOS)


def build_master(source: Path) -> Image.Image:
    art = Image.open(source).convert("RGBA")
    side = min(art.size)
    left, top = (art.width - side) // 2, (art.height - side) // 2
    art = art.crop((left, top, left + side, top + side)).resize((BODY, BODY), Image.LANCZOS)

    mask = squircle_mask(BODY)
    body = Image.new("RGBA", (BODY, BODY))
    body.paste(art, (0, 0), mask)

    offset = (CANVAS - BODY) // 2
    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    shadow_alpha = Image.new("L", (CANVAS, CANVAS), 0)
    shadow_alpha.paste(mask.point(lambda a: a * 0.35), (offset, offset + 12))
    shadow.putalpha(shadow_alpha.filter(ImageFilter.GaussianBlur(14)))

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    canvas.alpha_composite(shadow)
    canvas.alpha_composite(body, (offset, offset))
    return canvas


def main() -> None:
    source = Path(sys.argv[1])
    root = Path(__file__).resolve().parent.parent
    master = build_master(source)
    master.save(root / "Resources/AppIcon-1024.png")

    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        for points in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                px = points * scale
                name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
                master.resize((px, px), Image.LANCZOS).save(iconset / name)
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(root / "Resources/AppIcon.icns")],
                       check=True)
    print("wrote Resources/AppIcon.icns and Resources/AppIcon-1024.png")


if __name__ == "__main__":
    main()
