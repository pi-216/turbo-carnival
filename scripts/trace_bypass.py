#!/usr/bin/env python3
"""Trace the existing face/hand BYPASS plumbing.

The founder reports: sometimes there are NO hands, and the grow-mask node then throws an
out-of-boundaries exception. The graph already contains GetMaskSizeAndCount nodes and two
LazySwitchKJ nodes -- this prints whether they are wired together or left dangling.
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
        return (1, x)


WANT = ["26", "46", "27", "58", "19", "23", "16", "24", "45", "29", "61", "20", "36", "21"]
for nid in WANT:
    if nid not in wf:
        print("node %-6s ABSENT" % nid)
        continue
    n = wf[nid]
    print("node %-6s %s" % (nid, n.get("class_type", "")))
    for k, v in (n.get("inputs") or {}).items():
        src = ""
        if isinstance(v, list) and len(v) == 2 and isinstance(v[0], str) and v[0] in wf:
            src = "   <- node %s (%s)" % (v[0], wf[v[0]].get("class_type", ""))
        print("        %-18s %-16s%s" % (k, v, src))
    c = consumers.get(nid)
    print("        consumed by: %s" % (", ".join(c) if c else "NONE (dangling)"))

print()
print("=== every node whose class mentions a switch / boolean / primitive / int ===")
for nid in sorted(wf, key=nkey):
    cls = wf[nid].get("class_type", "")
    if any(t in cls.lower() for t in ("switch", "boolean", "primitive", "int", "compare", "number")):
        keep = {k: v for k, v in (wf[nid].get("inputs") or {}).items()}
        c = consumers.get(nid)
        print("  node %-6s %-26s %s   -> %s" % (nid, cls, keep, ", ".join(c) if c else "NONE (dangling)"))

print()
print("=== the two LazySwitchKJ switches: what feeds them? ===")
for sid in ("19", "23"):
    ins = wf[sid].get("inputs", {})
    sw = ins.get("switch")
    print("  node %s switch = %r  (%s)" % (sid, sw, "WIRED to a node" if isinstance(sw, list) else "HARDCODED literal"))
    print("        on_true  = %r" % (ins.get("on_true"),))
    print("        on_false = %r" % (ins.get("on_false"),))
