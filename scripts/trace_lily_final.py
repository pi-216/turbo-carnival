#!/usr/bin/env python3
"""Final Lily trace: the ControlNet's actual image source, the model stack, and the canvas geometry."""
import json
import pathlib

P = pathlib.Path("/mnt/fscache/essdee/ComfyUI/user/default/workflows/turbo-one-step-Lily.json")
wf = json.loads(P.read_text())
nodes = {str(n.get("id")): n for n in wf.get("nodes", [])}
types = {k: v.get("type", "") for k, v in nodes.items()}
in_of = {}
for l in wf.get("links", []):
    in_of[(str(l[3]), l[4])] = (str(l[1]), l[2])

WANT = ["236", "252", "272", "209", "211", "87", "43", "81", "41", "97", "261", "114",
        "37", "55", "74", "267", "96", "115", "112", "59", "40", "38", "75", "4", "39",
        "50", "86", "88", "79", "60", "31", "63", "6", "34", "14", "33"]
print("%-6s %-30s %s" % ("id", "type", "widgets_values / link sources"))
for nid in WANT:
    n = nodes.get(nid)
    if not n:
        print("%-6s %-30s ABSENT" % (nid, "-"))
        continue
    srcs = []
    for i, inp in enumerate(n.get("inputs") or []):
        s = in_of.get((nid, i))
        if s:
            srcs.append("%s<-%s(%s)" % (inp.get("name"), s[0], types.get(s[0], "?")))
    w = n.get("widgets_values")
    print("%-6s %-30s %s%s" % (nid, n.get("type"), w if w is not None else "",
                               ("   " + " ".join(srcs)) if srcs else ""))

print()
print("=== LoRA loaders: which LoRAs at what strength (Lily) ===")
for nid, n in sorted(nodes.items(), key=lambda kv: int(kv[0])):
    if n.get("type") == "Power Lora Loader (rgthree)":
        print("  node %-6s widgets/dict:" % nid)
        print("     %s" % (n.get("widgets_values"),))
        for k, v in (n.get("properties") or {}).items():
            pass

S = json.loads(pathlib.Path("/home/tim/source/activity/turbo-carnival/comfy_workflows/turbo_one_step_v2/step1_generate.json").read_text())
print()
print("=== LoRA loaders (Sarah, api) ===")
for nid, n in sorted(S.items(), key=lambda kv: int(kv[0]) if kv[0].isdigit() else 0):
    if "LoraLoader" in n.get("class_type", ""):
        keep = {k: v for k, v in n["inputs"].items() if not isinstance(v, list)}
        print("  node %-6s %-32s %s" % (nid, n.get("class_type"), keep))
