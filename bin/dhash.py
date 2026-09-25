#!/usr/bin/env python3
"""Perceptual difference-hash (dHash) for the near-duplicate publish gate.

WHY THIS EXISTS
The publish path had no near-duplicate check at all. Instagram removed 36 of the
150 posts this account published, and every near-duplicate pair in the corpus
(dHash distance <= 6) sits inside that removed set while no surviving pair is
closer than d=7 -- and posts 138-142 once published the SAME image on five
consecutive days (d=0, all five from one collapsed render directory). This is the
hasher that Growth::NearDuplicateGate consumes; it lives in Python because this
bundle has no PNG decoder.

ALGORITHM -- FIXED, do not "improve" it without re-measuring the threshold.
Greyscale -> resize to 9x8 (LANCZOS) -> one bit per horizontal neighbour
comparison, MSB-first, 64 bits. This is byte-for-byte the function the
2026-09-24 corpus measurement used, so the recorded distances (removed set
min=0, p25=9, med=13; surviving set min=7) stay comparable.

Usage:
  dhash.py --image PATH [--image PATH ...]
  dhash.py --paths-file FILE          # one path per line (preferred for many)

Prints ONE JSON object per input path, in input order, on stdout:
  {"path": "...", "dhash": "0123456789abcdef", "width": 1024, "height": 1024, "error": null}

An undecodable path prints {"path": ..., "dhash": null, "error": "..."} and does
NOT abort the batch -- the caller decides, and the gate fails OPEN (an unreadable
render publishes exactly as it did before the gate existed).
"""
import argparse
import json
import sys


def dhash(path, size=8):
    """64-bit difference hash of the image at `path`.

    Returns (bits, width, height, error). `bits` is None when the image could
    not be decoded, with `error` carrying the reason.
    """
    from PIL import Image

    try:
        with Image.open(path) as im:
            width, height = im.size
            small = im.convert("L").resize((size + 1, size), Image.LANCZOS)
            # tobytes() of an "L" image is one byte per pixel, row-major -- exactly
            # the pixel order the neighbour comparison needs, and unlike
            # getdata() it is not deprecated.
            px = small.tobytes()
    except Exception as exc:  # unreadable / not an image / truncated
        return None, None, None, "%s: %s" % (type(exc).__name__, exc)

    bits = 0
    for row in range(size):
        base = row * (size + 1)
        for col in range(size):
            left = px[base + col]
            right = px[base + col + 1]
            bits = (bits << 1) | (1 if left > right else 0)
    return bits, width, height, None


def main():
    ap = argparse.ArgumentParser(description="dHash one or more images")
    ap.add_argument("--image", action="append", default=[],
                    help="image path (repeatable)")
    ap.add_argument("--paths-file", default=None,
                    help="file with one image path per line (blank lines ignored)")
    ap.add_argument("--size", type=int, default=8,
                    help="hash is size x size bits (default 8 -> 64 bits)")
    args = ap.parse_args()

    paths = list(args.image)
    if args.paths_file:
        try:
            with open(args.paths_file) as fh:
                paths.extend([ln.rstrip("\n") for ln in fh if ln.strip()])
        except Exception as exc:
            print(json.dumps({"error": "paths-file: %s" % exc}))
            sys.exit(1)

    if not paths:
        print(json.dumps({"error": "no images given"}))
        sys.exit(1)

    out = sys.stdout
    for path in paths:
        bits, width, height, err = dhash(path, size=args.size)
        out.write(json.dumps({
            "path": path,
            "dhash": None if bits is None else format(bits, "0%dx" % (args.size * args.size // 4)),
            "width": width,
            "height": height,
            "error": err,
        }) + "\n")
    out.flush()


if __name__ == "__main__":
    main()
