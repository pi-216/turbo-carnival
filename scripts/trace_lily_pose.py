#!/usr/bin/env python3
"""Trace Lily's canvas links: where the pose/ControlNet signal enters, and which masks feed what.

Canvas format stores links as [link_id, origin_node, origin_slot, target_node, target_slot, type].
"""
import json
import pathlib

P = pathlib.Path("/mnt/fscache/essdee/ComfyUI/user/default/workflows/turbo-one-step-Lily.json")
wf = json.loads(P.read_text())
nodes = {str(n.get("id")): n for n in wf.get("nodes", [])}
types = {k: v.get("type", "") for k, v in nodes.items()}

# canvas links
out_of = {}   # (node, slot) -> [(target_node, target_slot, type)]
in_of = {}    # (node, slot) -> (origin_node, origin_slot, type)
for l in wf.get("links", []):
    lid, on, os_, tn, ts, ty = l[0], str(l[1]), l[2], str(l[3]), l[4], (l[5] if len(l) > 5 else "")
    out_of.setdefault((on, os_), []).append((tn, ts, ty))
    in_of[(tn, ts)] = (on, os_, ty)


def label(nid):
    return "node %s (%s)" % (nid, types.get(nid, "?"))


print("=== what feeds the OpenPose / ControlNet chain ===")
for nid in ("247", "235", "237"):
    n = nodes.get(nid)
    if not n:
        continue
    print()
    print(label(nid))
    for i, inp in enumerate(n.get("inputs") or []):
        nm = inp.get("name")
        src = in_of.get((nid, i))
        if src:
            print("   %-14s <- node %s (%s) slot %s" % (nm, src[0], types.get(src[0], "?"), src[1]))
        else:
            print("   %-14s (widget) %s" % (nm, (n.get("widgets_values") or [None])[i]
                                            if i < len(n.get("widgets_values") or []) else None))
    for (on, os_), tgts in sorted(out_of.items()):
        if on == nid:
            for tn, ts, ty in tgts:
                nm = ((nodes.get(tn, {}).get("inputs") or [{}])[ts] or {}).get("name") if tn in nodes else "?"
                print("   -> node %s (%s) as %s" % (tn, types.get(tn, "?"), nm))

print()
print("=== the two guider chains: which conditioning reaches each SamplerCustomAdvanced ===")
for sid in ("84", "85"):
    n = nodes.get(sid)
    if not n:
        continue
    print()
    print(label(sid))
    for i, inp in enumerate(n.get("inputs") or []):
        src = in_of.get((sid, i))
        if src:
            print("   %-14s <- node %s (%s)" % (inp.get("name"), src[0], types.get(src[0], "?")))

print()
print("=== chain from each guider back to its conditioning source ===")
def walk(nid, depth=0, seen=None):
    seen = seen or set()
    if nid in seen or depth > 6:
        return
    seen.add(nid)
    n = nodes.get(nid)
    if not n:
        return
    for i, inp in enumerate(n.get("inputs") or []):
        src = in_of.get((nid, i))
        if src:
            print("   %s%s.%s <- node %s (%s)" % ("  " * depth, nid, inp.get("name"),
                                                  src[0], types.get(src[0], "?")))
            walk(src[0], depth + 1, seen)

for gid in [k for k, v in types.items() if v == "BasicGuider"]:
    print()
    print("guider", label(gid))
    walk(gid)

print()
print("=== CLIPSeg model loaders (both files) ===")
for nid, n in sorted(nodes.items(), key=lambda kv: int(kv[0])):
    if n.get("type") == "LoadCLIPSegModels+":
        print("  LILY  node %-5s widgets=%s  -> %s" % (nid, n.get("widgets_values"),
              [t[0] for k, v in out_of.items() if k[0] == nid for t in [t[0] for t in v]]))
S = json.loads(pathlib.Path("/home/tim/source/activity/turbo-carnival/comfy_workflows/turbo_one_step_v2/step1_generate.json").read_text())
for nid, n in sorted(S.items(), key=lambda kv: int(kv[0]) if kv[0].isdigit() else 0):
    if n.get("class_type") == "LoadCLIPSegModels+":
        print("  SARAH node %-5s inputs=%s" % (nid, {k: v for k, v in n["inputs"].items()
                                                    if not isinstance(v, list)}))

print()
print("=== ImageScale sizes (Lily output geometry) ===")
for nid, n in sorted(nodes.items(), key=lambda kv: int(kv[0])):
    if n.get("type") in ("EmptyLatentImage", "ImageScale"):
        print("  node %-5s %-18s %s" % (nid, n.get("type"), n.get("widgets_values")))
