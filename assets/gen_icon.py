#!/usr/bin/env python3
"""Generate the WoW Mobile app icon: a phone with a play glyph, worn gold on
dark (#d4a017 on #1a1208 — the client's palette).

Outputs (committed to the repo; regenerate only when the artwork changes):
    assets/icon-256.png    — PNG source (largest frame)
    assets/wowmobile.ico   — 16/32/48/256 multi-size Windows icon

Usage:  python3 assets/gen_icon.py   (requires Pillow)
The .ico is baked into wowstreamd.exe via server/cmd/wowstreamd/
rsrc_windows_amd64.syso — see the regen note in server/cmd/wowstreamd/rsrc.go.
"""

import os

from PIL import Image, ImageDraw

DARK = (0x1A, 0x12, 0x08, 255)  # deep umber background
GOLD = (0xD4, 0xA0, 0x17, 255)  # worn gold
GOLD_DIM = (0x8A, 0x69, 0x12, 255)  # shaded gold for depth

SS = 4  # supersampling factor for crisp downscales


def draw_icon(size: int) -> Image.Image:
    """Draw one frame at `size` px (rendered at SS x and downsampled)."""
    s = size * SS
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    def px(frac: float) -> float:
        return frac * s

    # Rounded-square background plate.
    d.rounded_rectangle(
        [px(0.02), px(0.02), px(0.98), px(0.98)],
        radius=px(0.22),
        fill=DARK,
        outline=GOLD_DIM,
        width=max(1, int(px(0.015))),
    )

    # Phone body: portrait rounded rect, gold outline.
    stroke = max(1, int(px(0.045)))
    d.rounded_rectangle(
        [px(0.30), px(0.14), px(0.70), px(0.86)],
        radius=px(0.09),
        outline=GOLD,
        width=stroke,
    )
    # Speaker slit and home dot for phone-ness (only visible at larger sizes).
    if size >= 32:
        d.rounded_rectangle(
            [px(0.44), px(0.185), px(0.56), px(0.205)], radius=px(0.01), fill=GOLD
        )
        r = px(0.018)
        cx, cy = px(0.5), px(0.815)
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=GOLD)

    # Play glyph, optically centered in the screen area (a touch right of
    # geometric center, as play triangles want).
    cy = 0.49
    d.polygon(
        [
            (px(0.435), px(cy - 0.10)),
            (px(0.435), px(cy + 0.10)),
            (px(0.60), px(cy)),
        ],
        fill=GOLD,
    )

    return img.resize((size, size), Image.LANCZOS)


def main() -> None:
    out_dir = os.path.dirname(os.path.abspath(__file__))
    frames = {size: draw_icon(size) for size in (16, 32, 48, 256)}

    png_path = os.path.join(out_dir, "icon-256.png")
    frames[256].save(png_path)

    ico_path = os.path.join(out_dir, "wowmobile.ico")
    # Pillow writes the extra sizes from the base image list.
    frames[256].save(
        ico_path,
        format="ICO",
        append_images=[frames[48], frames[32], frames[16]],
        sizes=[(256, 256), (48, 48), (32, 32), (16, 16)],
    )
    print(f"wrote {png_path} and {ico_path}")


if __name__ == "__main__":
    main()
