#!/usr/bin/env python3
"""Add the mask-empty guard to the v2 workflow -- the fix for "sometimes there is nothing to detect".

THE FAULT
---------
If no hands (or no head) are in frame, CLIPSeg returns an EMPTY mask. GrowMaskWithBlur survives it
(its dilation is guarded by `and output.max() > 0`), but `Bounded Image Crop with Mask` does not --
it computes the bbox with `torch.where(rows)[0][[0, -1]]` and raises
`IndexError: index is out of bounds for dimension with size 0` (was-ns/WAS_Node_Suite.py:12456).

WHY THE HALF-BUILT GUARD IN THE GRAPH CAN NEVER WORK
----------------------------------------------------
Nodes 26/46 are `GetMaskSizeAndCount`, whose outputs are (mask, width, height, count) with
`count = mask.shape[0]` -- the BATCH SIZE, which is 1 even for a completely empty mask. Every
downstream number is therefore constant, and the dangling `Int To Number` -> nothing chain that was
started for it could never detect emptiness. A mask-content signal is required instead.

THE FIX (all four links verified against node source)
-----------------------------------------------------
  grown mask (45 head / 29 hand)
    -> MaskToSEGS            `core.mask_to_segs` guards with np.nonzero and returns an empty list for
                             an empty mask -- safe, no bbox math on emptiness
    -> ImpactIsNotEmptySEGS  `return (segs[1] != [],)` -> BOOLEAN, False when there is nothing
    -> LazySwitchKJ.switch   LAZY: the branch not taken is never executed, so selecting the bypass
                             means the crashing crop/downloadstream never runs

Polarity: the boolean is TRUE when there IS content, so `switch=True` must select the INPAINTED
branch. The existing switches are wired the other way round (on_true = pass-through), so on_true and
on_false get SWAPPED. Result: content -> inpaint; nothing -> pass the image through untouched.

SCOPE ASSERTION (this is a structural change, not one leaf)
-----------------------------------------------------------
After building, every leaf path that existed in the baseline must be UNCHANGED except the four that
are deliberately rewired (`19.switch`, `23.switch`, `19.on_true`/`19.on_false`,
`23.on_true`/`23.on_false`). Adding nodes is allowed; silently altering an existing parameter is not.
"""
import hashlib
import json
import pathlib
import sys

REPO = pathlib.Path("/home/tim/source/activity/turbo-carnival")
DEFAULT_BASE = REPO / "comfy_workflows/turbo_one_step_v2/step1_generate.json"
DEFAULT_OUT = REPO / "comfy_workflows/turbo_one_step_v2_guard/step1_generate.json"


def cli():
    """--base/--out so the same guard transform can be applied to BOTH arms of a comparison.
    Applying it to both is what keeps it out of the comparison: it becomes a common
    transformation, and the arms then differ only in the experimental axis."""
    base, out = DEFAULT_BASE, DEFAULT_OUT
    a = sys.argv[1:]
    for i, x in enumerate(a):
        if x == "--base":
            base = pathlib.Path(a[i + 1])
        elif x == "--out":
            out = pathlib.Path(a[i + 1])
    return base, out


BASE, OUT = cli()

# pass config: (label, grown-mask node, switch node, inpainted branch, pass-through branch)
PASSES = [
    ("head", "45", "19", "20", "61"),
    ("hand", "29", "23", "36", "19"),
]
SEGS_IDS = {"head": "901", "hand": "902"}
NOTEMPTY_IDS = {"head": "911", "hand": "912"}

REWIRE = ("switch", "on_true", "on_false")


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
    var = json.loads(BASE.read_text())

    for label, mask_node, sw, inpainted, passthrough in PASSES:
        for nid in (SEGS_IDS[label], NOTEMPTY_IDS[label]):
            if nid in base:
                sys.exit("REFUSING: node id %s already exists -- pick another" % nid)
        if mask_node not in base:
            sys.exit("REFUSING: grown-mask node %s absent" % mask_node)

        var[SEGS_IDS[label]] = {
            "class_type": "MaskToSEGS",
            "inputs": {"mask": [mask_node, 0], "combined": False, "crop_factor": 1.5,
                       "bbox_fill": False, "drop_size": 10, "contour_fill": False},
        }
        var[NOTEMPTY_IDS[label]] = {
            "class_type": "ImpactIsNotEmptySEGS",
            "inputs": {"segs": [SEGS_IDS[label], 0]},
        }
        # swap the switch polarity, then point it at the sensor
        before = dict(var[sw]["inputs"])
        var[sw]["inputs"]["on_true"] = before["on_false"]     # True  -> inpainted
        var[sw]["inputs"]["on_false"] = before["on_true"]     # False -> pass through
        var[sw]["inputs"]["switch"] = [NOTEMPTY_IDS[label], 0]
        print("  %-5s mask %s -> MaskToSEGS(%s) -> ImpactIsNotEmptySEGS(%s) -> %s.switch"
              % (label, mask_node, SEGS_IDS[label], NOTEMPTY_IDS[label], sw))
        print("        %s: on_true %s -> inpainted %s ; on_false -> pass-through %s"
              % (sw, before["on_true"], inpainted, passthrough))

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(var, indent=2) + "\n")

    a, b = dict(leaves(base)), dict(leaves(var))
    added = [k for k in b if k not in a]
    removed = [k for k in a if k not in b]
    changed = [k for k in a if k in b and a[k] != b[k]]

    # A scalar `switch` widget becoming a LINK legitimately removes the scalar leaf `…switch` and adds
    # `…switch[0]`/`…switch[1]`. That is the intended rewire, not a scope violation.
    allowed_removed = {"%s.inputs.switch" % sw for _, _, sw, _, _ in PASSES}
    allowed_changed = tuple("%s.inputs.on" % sw for _, _, sw, _, _ in PASSES)
    removed_bad = [k for k in removed if k not in allowed_removed]
    unexpected = [k for k in changed if not k.startswith(allowed_changed)]

    print()
    print("added leaves   : %d  (new guard nodes)" % len(added))
    print("removed leaves : %d  (%d expected: scalar switch -> link)" % (len(removed), len(removed) - len(removed_bad)))
    print("changed leaves : %d" % len(changed))
    for k in sorted(changed):
        print("   %s: %r -> %r" % (k, a.get(k), b.get(k)))
    if removed_bad or unexpected:
        OUT.unlink()
        sys.exit("REFUSING: scope assertion failed (removed=%s unexpected=%s). Variant removed."
                 % (removed_bad, unexpected))

    print()
    print("SCOPE ASSERTION PASSED: no pre-existing parameter changed except the four switch rewires.")
    print("baseline sha256: %s" % hashlib.sha256(BASE.read_bytes()).hexdigest())
    print("guarded  sha256: %s" % hashlib.sha256(OUT.read_bytes()).hexdigest())
    print("OK: guarded workflow written to %s" % OUT)


main()
