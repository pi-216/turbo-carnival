#!/usr/bin/env python3
"""E4 decode. Pre-registered: one-sided sign test, H1 = RAISED preferred, N = 6.

Founder's picks and stated reasons, 2026-10-18:
  1: B   "better hands"
  2: B   "less bad hands"
  3: neither  "A has the straps of the outfit painted over at the shoulder level, but better hands"
  4: B   "A did not have enough strength to paint fully over the strap on the shoulder (left some
          ghosting), but B are not great hands"
  5: neither
  6: B   "A painted a nipple on the breast when painting in the arm OR B painted the nipple OUT of
          the breast when painting in the arm. B has better hands"
  plus: "In neither pair could I identify differences at the face level."
"""
import json
from math import comb
from pathlib import Path

ROOT = Path("/home/tim/Documents/obsidian/04 - projects/turbo-carnival/elo/e4-hand-padding-N6")
PICKS = {1: "B", 2: "B", 3: None, 4: "B", 5: None, 6: "B"}
REASONS = {
    1: "hands: better",
    2: "hands: less bad",
    3: "strap painted over (on A); A better hands",
    4: "strap ghosting (on A); B hands not great",
    5: "-",
    6: "nipple on/off breast during arm inpaint; B better hands",
}
# reason axes the founder actually used (NOT the two I pre-registered)
AXES = {
    1: ["hands"],
    2: ["hands"],
    3: ["garment/strap", "hands"],
    4: ["garment/strap", "hands"],
    5: [],
    6: ["breast/nipple intrusion", "hands"],
}

key = json.loads((ROOT / "blinding-key.json").read_text())
print("baseline padding %s  sha %s" % (key["arm_baseline"]["padding"], key["arm_baseline"]["workflow_sha256"][:16]))
print("raised   padding %s  sha %s" % (key["arm_raised"]["padding"], key["arm_raised"]["workflow_sha256"][:16]))
print()


def tail(k, n):
    return sum(comb(n, i) for i in range(k, n + 1)) / 2 ** n


tally = {"baseline": 0, "raised": 0}
print("%-5s %-10s %-9s %-8s %-9s %-9s %s" % ("pair", "seed", "A", "B", "pick", "winner", "reason"))
for i in range(1, 7):
    p = key["pairs"]["pair-%02d" % i]
    pick = PICKS[i]
    winner = None
    if pick:
        winner = p[pick]
        tally[winner] += 1
    print("%-5d %-10d %-9s %-8s %-9s %-9s %s" % (
        i, p["seed"], p["A"], p["B"], pick or "neither",
        (winner or "-"), REASONS[i]))

k_raised, n_dec = tally["raised"], sum(tally.values())
print()
print("tally:", tally, " (decisive pairs: %d)" % n_dec)
print()
print("READING 1 -- pre-registered denominator N=6, ties scored as NON-wins for the raised arm")
print("  raised %d/6 -> one-sided p = %.6f" % (k_raised, tail(k_raised, 6)))
print("READING 2 -- decisive pairs only (standard sign-test treatment of ties), N=%d" % n_dec)
print("  raised %d/%d -> one-sided p = %.6f" % (k_raised, n_dec, tail(k_raised, n_dec)))
print()
print("  pre-registered bar was 6/6 -> p = 0.015625.")
print("  Neither reading reaches it. The rule's power was cut by the two declared ties, which the")
print("  pre-registration did not size for.")
print()
print("REASON AXES the founder actually used (tally):")
axes = {}
for i, a in AXES.items():
    for x in a:
        axes[x] = axes.get(x, 0) + 1
for x, c in sorted(axes.items(), key=lambda kv: -kv[1]):
    print("  %-26s %d pair(s)" % (x, c))
print()
print("  I pre-registered TWO defect classes: 'disconnected limb' and 'face off-head'.")
print("  Reported counts: disconnected limb 0, face off-head 0 (founder: 'In neither pair could I")
print("  identify differences at the face level.'). Both pre-registered instruments found NOTHING.")
print("  The defects that actually appeared were garment/strap integrity and breast intrusion --")
print("  neither of which I had listed. The taxonomy has to come from observed failures, not guesses.")
