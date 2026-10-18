#!/usr/bin/env python3
"""Trace every Bounded Image Crop node's mask input and report whether that path is guarded.

The empty-mask fault is only fixed where the crop sits BEHIND a LazySwitchKJ. A crop reached
without passing a switch still runs on an empty mask and still raises
`IndexError: index is out of bounds for dimension with size 0`. Guarding one crop does not
protect the others — enumerate them all, or the fix is partial and looks complete.

Usage:  /usr/bin/python3 scripts/trace_crops.py <path-to-workflow.json>
"""
import json
import pathlib
import sys

CA = pathlib.Path("/home/tim/source/activity/turbo-carnival")


def ins(wf, i):
    """Link inputs of node i: {port: source_node_id}"""
    return {k: v[0] for k, v in (wf.get(str(i), {}).get("inputs") or {}).items()
            if isinstance(v, list) and v}


def main():
    p = pathlib.Path(sys.argv[1])
    if not p.is_absolute():
        p = CA / p
    wf = json.loads(p.read_text())
    if not any(str(k).isdigit() for k in wf):
        raise SystemExit("%s: not prompt format (canvas format needs dump_canvas_workflow.py)" % p)

    ct = {k: (v.get("class_type") or "?") for k, v in wf.items()}

    print("workflow : %s" % p)
    print("nodes    : %d" % len(wf))
    print("switches : %s" % sorted((k for k, v in ct.items() if v == "LazySwitchKJ"), key=int))
    print("guards   : %s" % sorted((k for k, v in ct.items()
                                    if v in ("MaskToSEGS", "ImpactNotEmptySEGS")), key=int))
    print()

    crops = sorted((k for k, v in ct.items() if "Bounded Image Crop" in v), key=int)
    print("=== %d Bounded Image Crop node(s) ===" % len(crops))
    unguarded = []
    for c in crops:
        print("node %s  %s" % (c, ct[c]))
        links = ins(wf, c)
        for k, v in sorted(links.items()):
            print("    %-12s <- node %s (%s)" % (k, v, ct.get(str(v), "?")))

        # Walk the mask input backwards looking for a switch on the path.
        nxt = links.get("mask") or links.get("mask_color")
        chain, guarded, seen = [], False, set()
        while nxt is not None and str(nxt) not in seen and len(chain) < 15:
            seen.add(str(nxt))
            ctype = ct.get(str(nxt), "?")
            chain.append("%s:%s" % (nxt, ctype))
            if ctype == "LazySwitchKJ":
                guarded = True
                break
            step = None
            for k, v in ins(wf, nxt).items():
                if k in ("mask", "masks", "input", "mask_opt"):
                    step = v
                    break
            nxt = step
        print("    mask chain : %s" % (" <- ".join(chain) if chain else "(none traced)"))
        print("    GUARDED    : %s" % ("yes -- behind a LazySwitchKJ" if guarded
                                       else "*** NO -- still crashes on an empty mask ***"))
        if not guarded:
            unguarded.append(c)
        print()

    print("=== switches ===")
    for s in sorted((k for k, v in ct.items() if v == "LazySwitchKJ"), key=int):
        print("node %s" % s)
        for k, v in sorted(ins(wf, s).items()):
            print("    %-12s <- node %s (%s)" % (k, v, ct.get(str(v), "?")))
        # who consumes this switch's output?
        consumers = [k for k, v in wf.items() if any(
            isinstance(x, list) and x and str(x[0]) == str(s) for x in (v.get("inputs") or {}).values())]
        print("    consumed by: %s" % [(k, ct.get(k, "?")) for k in consumers])
        print()

    print("RESULT: %d of %d crop(s) guarded%s" % (len(crops) - len(unguarded), len(crops),
                                                  "" if not unguarded else "  -- UNGUARDED: %s" % unguarded))
    return 1 if unguarded else 0


sys.exit(main())
