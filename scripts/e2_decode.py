"""Decode the E2 blinded ranking and apply the PRE-REGISTERED decision rule.

Rule fixed in docs/experiment-backlog.md (E2) BEFORE any render or ranking. This script exists
so the analysis cannot drift after the fact: it computes the exact binomial p-value and prints
the pre-registered verdict, so a 5/6 cannot be narrated into a pass afterwards.

Usage:  /usr/bin/python3 scripts/e2_decode.py --table
        /usr/bin/python3 scripts/e2_decode.py --answers "1=B,2=A,3=B,4=B,5=A,6=B"

`--table` prints the whole decision rule up front, so the thresholds are checkable without
knowing any outcome. `--answers` reveals the blinding key and applies the rule.

Notes on convention (see the E2 doc): the test is ONE-SIDED, H1 = "PM25 preferred".
6/6 -> p = 0.015625 (one-sided), 0.03125 (two-sided). 5/6 -> p = 0.109375 (one-sided).
An earlier draft of the pre-registration mislabelled the two-sided 0.031 as one-sided; the
decision is unchanged either way, but this script reports both so the label cannot confuse it.
"""
import argparse
import json
import pathlib
from math import comb

ROOT = pathlib.Path(
    "/home/tim/Documents/obsidian/04 - projects/turbo-carnival/elo/kitchen-apron-pm25-vs-pm40-N6"
)
KEY = ROOT / "blinding-key.json"
N = 6


def one_sided(wins, n=N):
    """P(X >= wins) under the null, exact."""
    return sum(comb(n, k) for k in range(wins, n + 1)) / 2**n


def print_table():
    print("Pre-registered rule: ONE-SIDED sign test, H1 = PM25 preferred, n = 6")
    print()
    print("  wins for PM25   one-sided p      two-sided p")
    for w in range(N, 3, -1):
        p = one_sided(w)
        print("      %d/6         %-15.6f %.6f" % (w, p, min(1.0, 2 * p)))
    print()
    print("  decisive only at 6/6 (one-sided p = %.6f, below 0.05)." % one_sided(6))
    print("  5/6 does NOT clear the bar (p = %.6f)." % one_sided(5))
    print("  N is not to be extended after peeking.")


def decode(answers):
    if not KEY.is_file():
        raise SystemExit(f"no blinding key at {KEY} -- the replication has not finished")
    key = json.loads(KEY.read_text())
    pairs = key["pairs"]

    parsed = {}
    for chunk in answers.split(","):
        chunk = chunk.strip()
        if not chunk:
            continue
        pid, _, letter = chunk.partition("=")
        pid = pid.strip()
        letter = letter.strip().upper()
        if letter not in ("A", "B"):
            raise SystemExit(f"bad letter for {pid!r}: {letter!r} (use A or B)")
        parsed[pid] = letter

    print("E2 -- PM25 vs PM40, blinded decode")
    print("  scene        :", key["scene"])
    print("  decision rule:", key["decision_rule"])
    print()
    print("  pair   seed        your pick   A was      B was      => preferred")
    wins = losses = 0
    unreadable = []
    for pid in sorted(pairs):
        entry = pairs[pid]
        pick = parsed.get(pid)
        a_cp, b_cp = entry["A"], entry["B"]
        if pick is None:
            print("  %-6s %-11s %-11s %-10s %-10s %s"
                  % (pid, entry["seed"], "(no answer)", a_cp, b_cp, "--"))
            unreadable.append(pid)
            continue
        chosen = a_cp if pick == "A" else b_cp
        is_pm25 = "PM25" in chosen
        wins += 1 if is_pm25 else 0
        losses += 0 if is_pm25 else 1
        print("  %-6s %-11s %-11s %-10s %-10s %s"
              % (pid, entry["seed"], pick, a_cp, b_cp, "PM25" if is_pm25 else "PM40"))

    answered = wins + losses
    print()
    print("  answered: %d/%d   PM25 wins: %d   PM40 wins: %d" % (answered, len(pairs), wins, losses))

    if answered < len(pairs):
        print()
        print("  VERDICT: INCOMPLETE -- %d pair(s) unanswered (%s)." % (len(unreadable), ", ".join(unreadable)))
        print("  The pre-registered rule needs every pair; partial data cannot be read as a result")
        print("  in either direction. Collect the missing answers and re-run.")
        return 0

    p_one = one_sided(wins, answered)
    p_two = min(1.0, 2 * p_one)
    print()
    print("  one-sided p = %.6f   (two-sided %.6f)" % (p_one, p_two))
    print()
    if wins == answered:
        print("  VERDICT: DECISIVE -- unanimous for PM25 (%d/%d), p = %.6f < 0.05." % (wins, answered, p_one))
        print("  PM25 carries a measurable preference over PM40 at this N and this scene.")
    else:
        print("  VERDICT: NO MEASURABLE PREFERENCE at N=%d." % answered)
        print("  The pre-registered bar was unanimity (6/6). At %d/%d, p = %.6f does not clear" % (wins, answered, p_one))
        print("  0.05, so the honest conclusion is that this test did not detect a preference --")
        print("  the checkpoint choice should be made on other grounds (failure rate, throughput,")
        print("  the founder's prior fondness for Pornmaster), NOT on a tie-break.")
        print("  Do NOT extend N now: that is exactly the post-hoc chasing the pre-registration forbids.")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--answers", help='e.g. "1=B,2=A,3=B,4=B,5=A,6=B"')
    ap.add_argument("--table", action="store_true", help="print the decision rule only")
    args = ap.parse_args()
    print_table()
    if args.answers:
        print()
        return decode(args.answers)
    print()
    print("(pass --answers to decode a ranking)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
