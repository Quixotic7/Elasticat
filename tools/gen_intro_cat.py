#!/usr/bin/env python3
"""Bake images/gridcatanim.png (16x8 per frame, 55 frames) into a Lua table of
grid levels for the launch intro.

The monome grid is a 16x8 monochrome display with 16 brightness levels (0-15),
and norns has no runtime way to read PNG pixels for grid output -- so we
pre-convert the spritesheet's pixel luminance to grid levels at build time.

Usage: python3 tools/gen_intro_cat.py
Writes: lib/intro_cat_frames.lua
"""
import os
from PIL import Image

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(HERE, "images", "gridcatanim.png")
DST = os.path.join(HERE, "lib", "intro_cat_frames.lua")
FW, FH = 16, 8


def level(v):
    """Luminance 0-255 -> grid level 0-15."""
    return round(v / 255 * 15)


def main():
    im = Image.open(SRC).convert("L")
    w, h = im.size
    assert h == FH and w % FW == 0, (w, h)
    nframes = w // FW
    px = im.load()

    out = [
        "-- Auto-generated from images/gridcatanim.png (16x8, %d frames)." % nframes,
        "-- Each frame is 8 rows of 16 hex digits; each digit is a grid level 0-15.",
        "-- Regenerate: python3 tools/gen_intro_cat.py",
        "return {",
    ]
    for f in range(nframes):
        rows = ['"%s"' % "".join("%x" % level(px[f * FW + x, y]) for x in range(FW))
                for y in range(FH)]
        out.append("  {" + ", ".join(rows) + "},")
    out.append("}")
    with open(DST, "w") as fh:
        fh.write("\n".join(out) + "\n")
    print("wrote", DST, nframes, "frames")


if __name__ == "__main__":
    main()
