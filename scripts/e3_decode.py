#!/usr/bin/env python3
"""E3 decode. Pre-registered rule: one-sided sign test, H1 = PM25 preferred, N = 6.

Founder's picks (2026-10-18):
  1: A   (hands have some trouble)
  2: B
  3: A   (B shows nude behind)
  4: A   (B shows nipples)
  5: ?   ("don't know")
  6: B   (strong)

The pre-registration did NOT define a tie convention. That gap is reported, not papered over.
"""
import json
from math import comb
from pathlib import Path

ROOT = Path("/home/tim/Documents/obsidian/04 - projects/turbo-carnival/elo/bedroom-front-pm25-vs-pm40-N6")
PICKS = {1: "A", 2: "B", 3: "A", 4: "A", 5: None, 6: "B"}
# Pairs where the founder's stated reason was a DEFECT (lane violation), not a preference
DEFECT_DRIVEN = {3, 4}
AXIS = {1: "hands", 2: "overall", 3: "nude behind", 4: "nipples", 5: "indecisive", 6: "overall"}

key = json.loads((ROOT / "blinding-key.json").read_text())
print("frozen workflow sha256:", key["frozen_workflow_sha256"])
print("decision rule (as pre-registered):", key["decision_rule"])
print()

def tail_one_sided(k, n):
    """P(X >= k) for X ~ Binomial(n, 0.5) -- the one-sided sign test."""
    return sum(comb(n, i) for i in range(k, n + 1)) / 2 ** n

rows, tally = [], {"PM25": 0, "PM40": 0}
for i in range(1, 7):
    p = key["pairs"]["pair-%02d" % i]
    pick = PICKS[i]
    a_ck = p["A"]
    chosen = None
    if pick:
        chosen = p["A"] if pick == "A" else p["B"]
        tally[chosen.replace("CRPv18_", "").replace(".safetensors", "")] += 1
    rows.append((i, p["seed"], a_ck, p["B"], pick, chosen, AXIS[i]))

print("%-5s %-10s %-24s %-24s %-5s %-9s %s" % ("pair", "seed", "A", "B", "pick", "chosen", "why"))
for i, seed, a, b, pick, chosen, why in rows:
    print("%-5d %-10d %-24s %-24s %-5s %-9s %s" % (
        i, seed, a.replace("CRPv18_", "").replace(".safetensors", ""),
        b.replace("CRPv18_", "").replace(".safetensors", ""),
        pick or "-", (chosen or "-").replace("CRPv18_", "").replace(".safetensors", ""), why))

print()
print("tally:", tally)

n_dec = sum(1 for i in range(1, 7) if PICKS[i])
k25 = tally["PM25"]
print()
print("READING 1 -- pre-registered shape, N=6, tie counted as NOT a PM25 win")
print("  PM25 wins %d/6 -> one-sided p = %.6f" % (k25, tail_one_sided(k25, 6)))
print("READING 2 -- decisive pairs only (pair 5 excluded), N=%d" % n_dec)
print("  PM25 wins %d/%d -> one-sided p = %.6f" % (k25, n_dec, tail_one_sided(k25, n_dec)))
print()
print("  pre-registered thresholds were 6/6 -> 0.015625 (reject) and 5/6 -> 0.109375 (no preference).")
print("  Neither maps cleanly onto %d/%d, because no tie convention was pre-registered." % (k25, n_dec))

print()
print("ATTRIBUTION BY AXIS (whole point of the capture requirement)")
for i, seed, a, b, pick, chosen, why in rows:
    if not pick:
        continue
    loser = b if pick == "A" else a
    print("  pair %d (%s): %s beat %s" % (i, why, chosen.replace("CRPv18_", "").replace(".safetensors", ""),
                                          loser.replace("CRPv18_", "").replace(".safetensors", "")))

dd = [i for i in DEFECT_DRIVEN]
print()
print("defect-driven picks (lane violations, not preference): pairs %s" % dd)
for i in dd:
    p = key["pairs"]["pair-%02d" % i]
    loser = p["B"] if PICKS[i] == "A" else p["A"]
    print("  pair %d: the DEFECT was %s" % (i, loser.replace("CRPv18_", "").replace(".safetensors", "")))
