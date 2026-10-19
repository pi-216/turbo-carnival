#!/usr/bin/env python3
"""Create the E4 raised-padding workflow variant from the frozen baseline.

Single-axis discipline is ENFORCED here, not asserted: after writing the variant this script
re-reads both files, diffs every leaf path, and DELETES the variant and exits non-zero unless
exactly one leaf changed. "One axis per test" is otherwise a promise; this makes it a fact.

Axis: node 66 `DF_Integer` -> the hand crop padding, consumed by nodes 30 and 64
      (`Bounded Image Crop with Mask` on the grown HAND mask from node 29).
      Node 47 is the FACE padding and is deliberately untouched.
"""
import hashlib
import json
import pathlib
import sys

REPO = pathlib.Path("/home/tim/source/activity/turbo-carnival")
BASE = REPO / "comfy_workflows/turbo_one_step_v2/step1_generate.json"
VAR = REPO / "comfy_workflows/turbo_one_step_v2_e4_padding/step1_generate.json"

PAD_NODE = "66"
EXPECT_BASE_VALUE = 9.74609375
RAISED_VALUE = 48


def leaves(obj, prefix=""):
    if isinstance(obj, dict):
        for k, v in obj.items():
            yield from leaves(v, "%s.%s" % (prefix, k) if prefix else str(k))
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            yield from leaves(v, "%s[%d]" % (prefix, i))
    else:
        yield prefix, obj


def main():
    base = json.loads(BASE.read_text())
    node = base.get(PAD_NODE)
    if node is None or node.get("class_type") != "DF_Integer":
        sys.exit("REFUSING: node %s is not the expected DF_Integer" % PAD_NODE)
    got = float(node["inputs"]["Value"])
    if abs(got - EXPECT_BASE_VALUE) > 1e-6:
        sys.exit("REFUSING: baseline padding is %r, expected %r -- the baseline moved; "
                 "re-read the graph before changing the axis" % (got, EXPECT_BASE_VALUE))

    var = json.loads(BASE.read_text())
    var[PAD_NODE]["inputs"]["Value"] = RAISED_VALUE
    VAR.parent.mkdir(parents=True, exist_ok=True)
    VAR.write_text(json.dumps(var, indent=2) + "\n")

    a, b = dict(leaves(base)), dict(leaves(var))
    diff = sorted(k for k in set(a) | set(b) if a.get(k, "<missing>") != b.get(k, "<missing>"))
    print("changed leaf paths: %d" % len(diff))
    for k in diff:
        print("   %s: %r -> %r" % (k, a.get(k), b.get(k)))
    if len(diff) != 1:
        VAR.unlink()
        sys.exit("REFUSING: expected exactly ONE changed leaf (that is the one axis). Variant removed.")

    print()
    print("axis: hand crop padding  %s -> %s   (node %s, feeds nodes 30 + 64)" % (got, RAISED_VALUE, PAD_NODE))
    print("face padding (node 47) untouched at %s" % base["47"]["inputs"]["Value"])
    print("feathering (nodes 20, 36) untouched at %s"
          % [base["20"]["inputs"]["feathering"], base["36"]["inputs"]["feathering"]])
    print()
    print("baseline sha256: %s" % hashlib.sha256(BASE.read_bytes()).hexdigest())
    print("variant  sha256: %s" % hashlib.sha256(VAR.read_bytes()).hexdigest())
    print("OK: single-axis variant written to %s" % VAR)


main()
