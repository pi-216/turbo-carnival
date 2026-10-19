#!/usr/bin/env python3
"""Inventory the inpaint-composite knobs in the v2 workflow.

The founder flagged that 'Bounded Image Blend' carries feathering + blend_factor and that the
SAME process serves face and hands. This prints the truth: which nodes exist, which are literally
shared, what values they carry, and who consumes them.
"""
import collections
import json
import pathlib

WF = pathlib.Path("/home/tim/source/activity/turbo-carnival/comfy_workflows/turbo_one_step_v2/step1_generate.json")
wf = json.loads(WF.read_text())

consumers = collections.defaultdict(list)
for nid, n in wf.items():
    for k, v in (n.get("inputs") or {}).items():
        if isinstance(v, list) and len(v) == 2 and isinstance(v[0], str) and v[0] in wf:
            consumers[v[0]].append("%s.%s" % (nid, k))


def nkey(x):
    try:
        return (0, int(x))
    except ValueError:
        return (1, 0)


print("=== node class histogram (mask/blend/crop/composite family) ===")
for nid in sorted(wf, key=nkey):
    cls = wf[nid].get("class_type", "")
    if any(t in cls for t in ("Blend", "Crop", "Composite", "Mask")):
        print("  node %-8s %s" % (nid, cls))

print()
print("=== every input key containing feather / blend / mask, workflow-wide ===")
hits = 0
for nid in sorted(wf, key=nkey):
    for k, v in (wf[nid].get("inputs") or {}).items():
        if any(t in k.lower() for t in ("feather", "blend", "mask")):
            hits += 1
            src = ""
            if isinstance(v, list) and len(v) == 2 and isinstance(v[0], str) and v[0] in wf:
                src = "   <- node %s (%s)" % (v[0], wf[v[0]].get("class_type", ""))
            print("  %-8s %-28s %-24s %s%s" % (nid, wf[nid].get("class_type", ""), k, v, src))
print("  (%d hits)" % hits)

print()
print("=== detail: blend / crop nodes, their values and their consumers ===")
for nid in sorted(wf, key=nkey):
    cls = wf[nid].get("class_type", "")
    if any(t in cls for t in ("Blend", "Crop", "Composite")):
        print()
        print("node %s  %s" % (nid, cls))
        for k, v in (wf[nid].get("inputs") or {}).items():
            print("    %-24s %s" % (k, v))
        print("    consumed by: %s" % (", ".join(consumers.get(nid, [])) or "NONE"))

print()
print("=== the two inpaint samplers and what each composites back with ===")
for nid in sorted(wf, key=nkey):
    cls = wf[nid].get("class_type", "")
    if cls == "SamplerCustomAdvanced":
        ins = wf[nid].get("inputs", {})
        print("  node %-8s sampler; latent/denoise source chain: sampler=%s sigmas=%s"
              % (nid, ins.get("sampler"), ins.get("sigmas")))
        print("           consumed by: %s" % (", ".join(consumers.get(nid, [])) or "NONE"))

print()
print("=== the rest of the knob surface (mask grow, padding, mask thresholds) ===")
FOCUS = ["16", "24", "45", "29", "26", "46", "47", "66", "63", "31", "6", "34", "14", "33",
         "32", "35", "80", "68", "61", "19", "49", "67", "23", "7", "8"]
for nid in FOCUS:
    if nid not in wf:
        continue
    n = wf[nid]
    print()
    print("node %s  %s" % (nid, n.get("class_type", "")))
    for k, v in (n.get("inputs") or {}).items():
        src = ""
        if isinstance(v, list) and len(v) == 2 and isinstance(v[0], str) and v[0] in wf:
            src = "   <- node %s (%s)" % (v[0], wf[v[0]].get("class_type", ""))
        print("    %-22s %-22s%s" % (k, v, src))
    print("    consumed by: %s" % (", ".join(consumers.get(nid, [])) or "NONE"))

print()
print("=== duplicate-vs-shared: which knobs exist once and which exist twice ===")
for cls_filter, label in (("Bounded Image Blend", "blend"),
                          ("Bounded Image Crop with Mask", "crop"),
                          ("GrowMaskWithBlur", "mask grow"),
                          ("ApplyCLIPSeg", "mask threshold")):
    ids = [i for i in sorted(wf, key=nkey) if wf[i].get("class_type", "") == cls_filter]
    print("  %-16s %d instance(s): %s" % (label, len(ids), ids))
    for i in ids:
        keep = {k: v for k, v in (wf[i].get("inputs") or {}).items()
                if not (isinstance(v, list) and len(v) == 2)}
        print("        node %-8s %s" % (i, keep))
