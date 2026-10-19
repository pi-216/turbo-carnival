#!/usr/bin/env python3
"""Dump the inpaint-relevant nodes of a ComfyUI CANVAS-format workflow (nodes/links/widgets_values).

Canvas format stores widget values as a positional list, so reading them requires knowing each
class's declared input order. This prints type + raw widgets_values + input names so the alignment
is checkable rather than assumed.
"""
import collections
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
wf = json.loads(path.read_text())
nodes = wf.get("nodes", [])
print("file: %s   nodes: %d   format: %s" % (path.name, len(nodes), "canvas" if "nodes" in wf else "api"))

hist = collections.Counter(n.get("type", "?") for n in nodes)
print()
print("=== node type histogram ===")
for t, c in sorted(hist.items()):
    print("  %-34s %d" % (t, c))

INTEREST = ("CLIPSeg", "GrowMaskWithBlur", "Bounded Image", "ImageResize", "ImageToMask",
            "SetLatentNoiseMask", "Scheduler", "Sampler", "SwitchKJ", "MaskToImage",
            "MaskSizeAndCount", "Int To Number", "Constant Number", "Text", "CLIPTextEncode")

print()
print("=== nodes of interest, in canvas id order ===")
for n in sorted(nodes, key=lambda n: n.get("id", 0)):
    t = n.get("type", "")
    if not any(k.lower() in t.lower() for k in INTEREST):
        continue
    w = n.get("widgets_values")
    ins = [i.get("name") for i in (n.get("inputs") or []) if i.get("widget") is None]
    wnames = [i.get("name") for i in (n.get("inputs") or []) if i.get("widget") is not None]
    print()
    print("id %-5s %s" % (n.get("id"), t))
    if w is not None:
        print("     widgets_values : %s" % (w,))
    if wnames:
        print("     widget names   : %s" % (wnames,))
    if ins:
        print("     link inputs    : %s" % (ins,))
