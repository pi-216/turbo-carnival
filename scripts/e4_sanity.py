#!/usr/bin/env python3
"""E4 sanity: did the padding axis actually change the pixels?

If baseline and raised renders are (near-)identical the test is VACUOUS and must be reported as such
rather than handed to the founder as a ranking task. Prints per-seed difference statistics.
"""
import pathlib
import sys

from PIL import Image, ImageChops

ROOT = pathlib.Path("/home/tim/Documents/obsidian/04 - projects/turbo-carnival/elo/e4-hand-padding-N6")
SEEDS = [20261201, 20261202, 20261203, 20261204, 20261205, 20261206]

print("%-10s %-7s %-9s %-9s %-11s %s" % ("seed", "size", "meanAbs", "maxAbs", "pct>8", "verdict"))
rows = []
for seed in SEEDS:
    a = ROOT / "baseline" / ("seed-%d" % seed) / "bedroom-front__CRPv18_PM40.png"
    b = ROOT / "raised" / ("seed-%d" % seed) / "bedroom-front__CRPv18_PM40.png"
    if not (a.is_file() and b.is_file()):
        print("%-10d MISSING" % seed)
        continue
    ia, ib = Image.open(a).convert("RGB"), Image.open(b).convert("RGB")
    same_size = ia.size == ib.size
    diff = ImageChops.difference(ia, ib)
    gray = diff.convert("L")
    hist = gray.histogram()
    total = sum(hist)
    mean_abs = sum(i * n for i, n in enumerate(hist)) / total
    max_abs = max(i for i, n in enumerate(hist) if n)
    pct8 = 100.0 * sum(hist[9:]) / total
    verdict = "no change" if max_abs == 0 else ("negligible" if pct8 < 0.5 else "different")
    print("%-10d %-7s %-9.3f %-9d %-11.2f %s" % (seed, "same" if same_size else "DIFF", mean_abs, max_abs, pct8, verdict))
    rows.append((seed, mean_abs, pct8, verdict))

print()
bad = [r for r in rows if r[3] == "no change"]
neg = [r for r in rows if r[3] == "negligible"]
if bad:
    print("VACUOUS: %d/%d pairs are pixel-identical -- the axis did not bite. DO NOT rank these." % (len(bad), len(rows)))
    sys.exit(1)
if neg:
    print("CAUTION: %d/%d pairs are near-identical (<0.5%% of pixels differ). The axis barely bit;"
          % (len(neg), len(rows)))
    print("         a ranking on these would mostly measure noise. Report that honestly.")
else:
    print("OK: all %d pairs differ substantively -- the axis bit, the ranking is informative." % len(rows))
