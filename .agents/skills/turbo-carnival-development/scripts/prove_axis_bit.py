#!/usr/bin/env python3
"""Prove the experimental axis actually bit, BEFORE asking anyone to rank the pairs.

A paired ranking is only worth the rater's attention if the two arms differ. If the
config change did not move the pixels, the pair set is VACUOUS: a null result would be
recorded as "no preference" when it is really "no difference to see". Run this between
rendering and delivering the sheets (see references/experiment-harness.md, order of
operations step 11).

Expects a per-seed directory layout, which is what the blinded pair harness produces:

    <A>/seed-20261201/<name>      <B>/seed-20261201/<name>
    <A>/seed-20261202/<name>      <B>/seed-20261202/<name>

The filename does not leak the arm (both dirs hold the same basename), so pass it once.

Usage:
    /usr/bin/python3 prove_axis_bit.py --a DIR_A --b DIR_B --name 'scene__ckpt.png'

Exit codes: 0 = informative, 1 = VACUOUS (identical pairs), 2 = setup problem.
Pin the interpreter: a background job may resolve a different python3, and PIL may only
be present on one of them (see references/render-pipeline-operations.md).
"""
import argparse
import pathlib
import re
import sys

from PIL import Image, ImageChops  # top-level on purpose: fail before any work


def seed_key(p):
    m = re.search(r"(\d+)", p.name)
    return int(m.group(1)) if m else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--a", required=True, help="arm A run directory (parent of seed-*/ dirs)")
    ap.add_argument("--b", required=True, help="arm B run directory")
    ap.add_argument("--name", required=True, help="the per-seed PNG basename, identical in both arms")
    ap.add_argument("--min-pct", type=float, default=0.5,
                    help="below this %% of changed pixels a pair is 'near-identical' (default 0.5)")
    args = ap.parse_args()

    A, B = pathlib.Path(args.a), pathlib.Path(args.b)
    for d in (A, B):
        if not d.is_dir():
            print("setup error: not a directory: %s" % d)
            return 2

    seeds = sorted([d for d in A.iterdir() if d.is_dir()], key=seed_key)
    if not seeds:
        print("setup error: no seed-*/ directories under %s" % A)
        return 2

    print("%-12s %-7s %-9s %-9s %-11s %s" % ("seed", "size", "meanAbs", "maxAbs", "pct>8", "verdict"))
    rows, missing = [], []
    for d in seeds:
        pa, pb = d / args.name, B / d.name / args.name
        if not (pa.is_file() and pb.is_file()):
            missing.append(d.name)
            print("%-12s MISSING (%s | %s)" % (d.name, pa.is_file(), pb.is_file()))
            continue
        ia, ib = Image.open(pa).convert("RGB"), Image.open(pb).convert("RGB")
        same_size = ia.size == ib.size
        gray = ImageChops.difference(ia, ib).convert("L")
        hist = gray.histogram()
        total = sum(hist)
        mean_abs = sum(i * n for i, n in enumerate(hist)) / total
        max_abs = max(i for i, n in enumerate(hist) if n)
        pct = 100.0 * sum(hist[9:]) / total
        verdict = "IDENTICAL" if max_abs == 0 else ("near-identical" if pct < args.min_pct else "differs")
        print("%-12s %-7s %-9.3f %-9d %-11.2f %s"
              % (d.name, "same" if same_size else "DIFF", mean_abs, max_abs, pct, verdict))
        rows.append((d.name, verdict))

    print()
    if missing:
        print("INCOMPLETE: %d seed dir(s) missing a render in one arm: %s" % (len(missing), ", ".join(missing)))
        print("Do not rank a partial set -- fill it or abort for cause.")
        return 2

    identical = [n for n, v in rows if v == "IDENTICAL"]
    if identical:
        print("VACUOUS: %d/%d pairs are pixel-identical (%s)." % (len(identical), len(rows), ", ".join(identical)))
        print("The axis did not bite. Do NOT deliver these as a ranking task -- say the test is vacuous,")
        print("fix or widen the axis, and re-render.")
        return 1

    near = [n for n, v in rows if v == "near-identical"]
    if near:
        print("CAUTION: %d/%d pairs are near-identical (<%.2f%% of pixels changed: %s)."
              % (len(near), len(rows), args.min_pct, ", ".join(near)))
        print("A ranking on these mostly measures noise. Deliver only with that stated, or widen the axis.")
        return 0

    print("OK: all %d pairs differ substantively -- the axis bit, the ranking is informative." % len(rows))
    return 0


if __name__ == "__main__":
    sys.exit(main())
