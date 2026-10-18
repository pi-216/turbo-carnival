#!/usr/bin/env python3
"""Labelled contact sheet -- a set of images with their FILENAMES burned in.

Why this exists: `MEDIA:` embeds render as bare images with no caption and no filename, so a
set of renders that differ only by checkpoint/seed is unreadable -- the reviewer cannot tell
which tile came from what. Burn the name into the tile and the ambiguity is gone.

Layout per tile: the checkpoint tail (text after `__`) in large type, the full filename in
small type underneath.

Usage:
    /usr/bin/python3 scripts/contact_sheet.py --out /tmp/x/sheet.png DIR_OR_FILES...

Targets may be directories (all *.png taken, sorted), globs, or individual files.
Run it with a PINNED interpreter (`/usr/bin/python3`) -- a backgrounded job can resolve a
different `python3`, and this machine has five on PATH, one of them Pillow-less.
"""
import argparse
import pathlib
import sys


def _fonts():
    from PIL import ImageFont

    try:
        return ImageFont.load_default(size=30), ImageFont.load_default(size=21)
    except TypeError:  # older Pillow: no size kwarg
        f = ImageFont.load_default()
        return f, f


def gather(targets):
    files = []
    for t in targets:
        p = pathlib.Path(t)
        if p.is_dir():
            files += sorted(p.glob("*.png"))
        elif any(c in p.name for c in "*?["):
            files += sorted(p.parent.glob(p.name))
        elif p.is_file():
            files.append(p)
        else:
            print("skipping (not found): %s" % t, file=sys.stderr)
    return files


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True, help="output sheet path")
    ap.add_argument("--cols", type=int, default=2)
    ap.add_argument("--cell", type=int, default=560, help="tile width in px")
    ap.add_argument("targets", nargs="+", help="directories, globs, or files")
    a = ap.parse_args()

    files = gather(a.targets)
    if not files:
        print("no images found", file=sys.stderr)
        return 1

    from PIL import Image, ImageDraw

    font, small = _fonts()
    pad, header, footer = 24, 34, 54
    first = Image.open(files[0])
    ratio = first.size[1] / first.size[0]
    ch = int(a.cell * ratio)
    cols = max(1, a.cols)
    rows = (len(files) + cols - 1) // cols
    W = pad * (cols + 1) + a.cell * cols
    H = pad * (rows + 1) + (header + ch + footer) * rows
    sheet = Image.new("RGB", (W, H), (247, 247, 245))
    d = ImageDraw.Draw(sheet)

    for i, f in enumerate(files):
        r, c = divmod(i, cols)
        x = pad + c * (a.cell + pad)
        y = pad + r * (header + ch + footer + pad)
        d.text((x, y + 4), f.name.split("__")[-1], fill=(15, 15, 15), font=font)
        im = Image.open(f).convert("RGB").resize((a.cell, ch), Image.Resampling.LANCZOS)
        sheet.paste(im, (x, y + header))
        d.text((x, y + header + ch + 10), f.name, fill=(110, 110, 110), font=small)

    out = pathlib.Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(out, optimize=True)
    print("sheet: %s  (%d images, %dx%d)" % (out, len(files), W, H))
    for f in files:
        print("   %s" % f.name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
