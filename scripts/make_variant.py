#!/usr/bin/env python3
"""Generic single-axis workflow variant maker, with the one-axis rule ENFORCED.

Writes a variant workflow, then re-reads both files, diffs every leaf path, and deletes the variant
and exits non-zero unless EXACTLY the expected leaves changed. "One axis per test" is otherwise a
promise; this makes it a fact. Generalises scripts/e4_make_variant.py.

Usage:
  make_variant.py --base BASE.json --out VAR.json \
                  --expect 96.inputs.cfg=5.5 --set 96.inputs.cfg=7
  (repeat --expect/--set for multi-leaf axes; the diff count must equal the number of --set ops)
"""
import hashlib
import json
import pathlib
import sys

REPO = pathlib.Path("/home/tim/source/activity/turbo-carnival")


def leaves(obj, prefix=""):
    if isinstance(obj, dict):
        for k, v in obj.items():
            yield from leaves(v, "%s.%s" % (prefix, k) if prefix else str(k))
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            yield from leaves(v, "%s[%d]" % (prefix, i))
    else:
        yield prefix, obj


def getpath(wf, path):
    """path is <node_id>.<...> e.g. 96.inputs.cfg"""
    cur = wf
    for part in path.split("."):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            raise KeyError(path)
    return cur


def setpath(wf, path, value):
    parts = path.split(".")
    cur = wf
    for part in parts[:-1]:
        if part not in cur:
            raise KeyError(path)
        cur = cur[part]
    old = cur[parts[-1]]
    cur[parts[-1]] = value
    return old


def numeq(a, b):
    try:
        return abs(float(a) - float(b)) < 1e-6
    except (TypeError, ValueError):
        return a == b


def coerce(s):
    """Typed CLI values. Without this a `--set 96.inputs.cfg=7` writes the STRING '7' into a field
    the node declares as FLOAT -- ComfyUI may coerce it silently or reject it, and either way the
    variant no longer matches what the axis claims. This exact class (string vs number) has already
    caused a silent-failure bug in this project's substitution chain."""
    low = s.lower()
    if low in ("true", "false"):
        return low == "true"
    try:
        f = float(s)
    except ValueError:
        return s
    return int(f) if ("." not in s and "e" not in low) else f


def same_kind(old, new):
    """Both numeric, both bool, or both str -- never change the VALUE TYPE as a side effect."""
    def kind(v):
        if isinstance(v, bool):
            return "bool"
        if isinstance(v, (int, float)):
            return "num"
        return "str"
    return kind(old) == kind(new)


def args():
    base = out = None
    expect, setp = [], []
    argv = sys.argv[1:]
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--base":
            base = argv[i + 1]; i += 2
        elif a == "--out":
            out = argv[i + 1]; i += 2
        elif a == "--expect":
            expect.append(argv[i + 1]); i += 2
        elif a == "--set":
            setp.append(argv[i + 1]); i += 2
        else:
            sys.exit("unknown arg %r" % a)
    if not (base and out and setp):
        sys.exit("need --base, --out and at least one --set")
    return pathlib.Path(base), pathlib.Path(out), expect, setp


def main():
    base_p, out_p, expect, setp = args()
    base = json.loads(base_p.read_text())

    for spec in expect:
        path, want = spec.split("=", 1)
        try:
            got = getpath(base, path)
        except KeyError:
            sys.exit("REFUSING: %s does not exist in the baseline -- the baseline moved" % path)
        if not numeq(got, want):
            sys.exit("REFUSING: baseline %s is %r, expected %r -- re-read the graph before "
                     "changing this axis" % (path, got, want))

    var = json.loads(base_p.read_text())
    for spec in setp:
        path, want = spec.split("=", 1)
        newval = coerce(want)
        try:
            old = getpath(var, path)
        except KeyError:
            sys.exit("REFUSING: cannot set %s" % path)
        if not same_kind(old, newval):
            sys.exit("REFUSING: %s is %s (%r); you asked to write a %s (%r). Refusing a type change "
                     "on a value axis." % (path, type(old).__name__, old,
                                           type(newval).__name__, newval))
        setpath(var, path, newval)
        print("  %s: %r (%s) -> %r (%s)" % (path, old, type(old).__name__, newval,
                                             type(newval).__name__))

    out_p.parent.mkdir(parents=True, exist_ok=True)
    out_p.write_text(json.dumps(var, indent=2) + "\n")

    a, b = dict(leaves(base)), dict(leaves(var))
    diff = sorted(k for k in set(a) | set(b) if a.get(k, "<missing>") != b.get(k, "<missing>"))
    print()
    print("changed leaf paths: %d  (expected %d)" % (len(diff), len(setp)))
    for k in diff:
        print("   %s: %r -> %r" % (k, a.get(k), b.get(k)))
    if len(diff) != len(setp):
        out_p.unlink()
        sys.exit("REFUSING: diff count %d != requested %d. Variant removed." % (len(diff), len(setp)))

    print()
    print("baseline sha256: %s" % hashlib.sha256(base_p.read_bytes()).hexdigest())
    print("variant  sha256: %s" % hashlib.sha256(out_p.read_bytes()).hexdigest())
    print("OK: single-axis variant written to %s" % out_p)


main()
