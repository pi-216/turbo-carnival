#!/usr/bin/env python3
"""Generic two-arm paired, blinded render harness.

Arms are two WORKFLOW FILES, so neither is ever mutated mid-sweep, each carries its own sha256 into
the blinding key, and the one-axis claim is checked mechanically (the arms must differ in EXACTLY
--expect-diff leaf paths).

Supersedes replicate_e3.py / replicate_e4.py (kept for provenance). Proven guards retained:
  * REFUSES if the scene file contains an HTML comment -- the pipeline sends the raw file.
  * Substring checks normalise whitespace first (the scene wraps; the bare word `front` collides).
  * Frozen config asserted in BOTH arms, so silent drift cannot masquerade as an arm effect.
  * Card must be free before the first render.
  * Pillow imported at module top ON PURPOSE: a missing Pillow aborts before the first render.
  * NEW: the axis is proven to BITE (per-seed pixel diff) before any ranking is requested, and a
    pixel-identical arm pair is reported as VACUOUS rather than handed over.
Run with a PINNED interpreter:  /usr/bin/python3 scripts/replicate_pairs.py ...
"""
import argparse
import hashlib
import json
import pathlib
import random
import re
import subprocess
import sys
import time

from PIL import Image, ImageChops, ImageDraw, ImageFont

REPO = pathlib.Path("/home/tim/source/activity/turbo-carnival")
MARGIN, HEADER, FOOTER = 28, 76, 56


def log(m):
    print(m, flush=True)


def norm(s):
    return re.sub(r"\s+", " ", s).strip()


def fonts():
    try:
        return ImageFont.load_default(size=34), ImageFont.load_default(size=26)
    except TypeError:
        f = ImageFont.load_default()
        return f, f


def leaves(obj, prefix=""):
    if isinstance(obj, dict):
        for k, v in obj.items():
            yield from leaves(v, "%s.%s" % (prefix, k) if prefix else str(k))
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            yield from leaves(v, "%s[%d]" % (prefix, i))
    else:
        yield prefix, obj


def card_free():
    return subprocess.run(["pgrep", "-f", "tc_rend[e]r.py sweep"], capture_output=True).returncode != 0


FROZEN = {
    "positive has 1girl, solo": lambda wf: "1girl, solo" in wf["88"]["inputs"]["text"],
    "negative has 2girls": lambda wf: "2girls" in wf["79"]["inputs"]["text"],
    "negative has nipples": lambda wf: "nipples" in wf["79"]["inputs"]["text"],
    "hand denoise >= 0.68": lambda wf: float(wf["113"]["inputs"]["denoise"]) >= 0.68,
    "face denoise == 0.66": lambda wf: abs(float(wf["110:109"]["inputs"]["denoise"]) - 0.66) < 1e-9,
    "flux tg LoRA off": lambda wf: wf["41"]["inputs"]["lora_3"].get("on") is False,
    "blend feathering == 10 (both)": lambda wf: (float(wf["20"]["inputs"]["feathering"]) == 10
                                                 and float(wf["36"]["inputs"]["feathering"]) == 10),
    "blend_factor == 1 (both)": lambda wf: (float(wf["20"]["inputs"]["blend_factor"]) == 1
                                            and float(wf["36"]["inputs"]["blend_factor"]) == 1),
}


def args():
    p = argparse.ArgumentParser()
    p.add_argument("--baseline", required=True)
    p.add_argument("--variant", required=True)
    p.add_argument("--out-root", required=True)
    p.add_argument("--label", required=True, help="experiment label, e.g. e5-base-cfg")
    p.add_argument("--scene", required=True, help="filename prefix")
    p.add_argument("--scene-file", required=True)
    p.add_argument("--checkpoint", required=True)
    p.add_argument("--seeds", required=True, help="comma-separated")
    p.add_argument("--blind-seed", type=int, required=True)
    p.add_argument("--expect-diff", type=int, default=1)
    p.add_argument("--question", default="")
    p.add_argument("--decision-rule", required=True)
    return p.parse_args()


def preflight(a):
    b_p, v_p = pathlib.Path(a.baseline), pathlib.Path(a.variant)
    for p in (b_p, v_p):
        if not p.is_file():
            log("REFUSING: missing workflow %s" % p)
            return None

    sf = pathlib.Path(a.scene_file)
    raw = sf.read_text()
    if "<!--" in raw:
        log("REFUSING: the scene file contains an HTML comment; the pipeline sends it raw.")
        return None
    log("preflight -- frozen config, per arm")
    shas = {}
    for label, p in (("baseline", b_p), ("variant", v_p)):
        wf = json.loads(p.read_text())
        bad = [k for k, fn in FROZEN.items() if not fn(wf)]
        for k, fn in FROZEN.items():
            log("  %-10s %-32s %s" % (label, k, "*** FAIL" if k in bad else "ok"))
        if bad:
            log("REFUSING: frozen config broken in the %s arm: %s" % (label, bad))
            return None
        shas[label] = hashlib.sha256(p.read_bytes()).hexdigest()

    A, B = dict(leaves(json.loads(b_p.read_text()))), dict(leaves(json.loads(v_p.read_text())))
    diff = sorted(k for k in set(A) | set(B) if A.get(k, "<missing>") != B.get(k, "<missing>"))
    log("  one-axis check: %d changed leaf path(s) (expected %d)" % (len(diff), a.expect_diff))
    for k in diff:
        log("     %s: %r -> %r" % (k, A.get(k), B.get(k)))
    if len(diff) != a.expect_diff:
        log("REFUSING: arms differ in %d leaves, expected %d -- not one axis." % (len(diff), a.expect_diff))
        return None

    log("  scene chars (whitespace-normalised): %d" % len(norm(raw)))
    return {"shas": shas, "changed": diff,
            "scene_sha256": hashlib.sha256(sf.read_bytes()).hexdigest()}


def wait_for_card(minutes=20):
    for _ in range(minutes * 6):
        if card_free():
            return True
        time.sleep(10)
    return False


def render(seed, arm, wf, a):
    out = pathlib.Path(a.out_root) / arm / ("seed-%d" % seed)
    out.mkdir(parents=True, exist_ok=True)
    cmd = [sys.executable, "bin/tc_render.py", "sweep", "--scene", a.scene,
           "--prompt-file", a.scene_file, "--out", str(out), "--checkpoints", a.checkpoint,
           "--workflow", str(wf), "--seed", str(seed), "--retries", "2"]
    log("  %-8s seed=%d" % (arm, seed))
    p = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True)
    for line in [l for l in (p.stdout or "").strip().splitlines() if l.strip()][-2:]:
        log("      " + line)
    if p.returncode != 0:
        log("      rc=%s %s" % (p.returncode, (p.stderr or "")[-200:]))
    return out / ("%s__%s.png" % (a.scene, pathlib.Path(a.checkpoint).stem))


def axis_bites(pb, pr):
    """Per-seed pixel diff. Returns (verdict, stats)."""
    ia, ib = Image.open(pb).convert("RGB"), Image.open(pr).convert("RGB")
    if ia.size != ib.size:
        return "size-mismatch", (0, 0, 0.0)
    hist = ImageChops.difference(ia, ib).convert("L").histogram()
    total = sum(hist)
    mean_abs = sum(i * n for i, n in enumerate(hist)) / total
    max_abs = max(i for i, n in enumerate(hist) if n)
    pct = 100.0 * sum(hist[9:]) / total
    verdict = "identical" if max_abs == 0 else ("negligible" if pct < 0.5 else "different")
    return verdict, (mean_abs, max_abs, pct)


def sheet(pa, pb, a_is_variant, i, a, root):
    font, fs = fonts()
    left = Image.open(pa if not a_is_variant else pb).convert("RGB")
    right = Image.open(pb if not a_is_variant else pa).convert("RGB")
    w, h = left.size
    s = Image.new("RGB", (MARGIN * 3 + w * 2, MARGIN * 2 + HEADER + h + FOOTER), (247, 247, 245))
    d = ImageDraw.Draw(s)
    d.text((MARGIN, MARGIN // 2 + 6), "PAIR %d  -  which do you prefer?" % i, fill=(20, 20, 20), font=font)
    top = MARGIN + HEADER
    s.paste(left, (MARGIN, top))
    s.paste(right, (MARGIN * 2 + w, top))
    d.text((MARGIN + w // 2 - 14, top - 34), "A", fill=(20, 20, 20), font=font)
    d.text((MARGIN * 2 + w + w // 2 - 14, top - 34), "B", fill=(20, 20, 20), font=font)
    d.text((MARGIN, top + h + 14), "pair %d" % i, fill=(110, 110, 110), font=fs)
    pairs = pathlib.Path(root) / "pairs"
    pairs.mkdir(parents=True, exist_ok=True)
    dest = pairs / ("pair-%02d.png" % i)
    s.save(dest, optimize=True)
    return dest


def main():
    a = args()
    root = pathlib.Path(a.out_root)
    root.mkdir(parents=True, exist_ok=True)
    log("label: %s   interpreter: %s" % (a.label, sys.executable))

    pf = preflight(a)
    if pf is None:
        return 2
    if not wait_for_card():
        log("REFUSING: the card never came free; not rendering a confounded set.")
        return 3

    seeds = [int(x) for x in a.seeds.split(",")]
    log("")
    log("rendering %d seeds x 2 arms (%d renders)" % (len(seeds), len(seeds) * 2))
    rendered = {}
    for seed in seeds:
        rendered[seed] = {
            "baseline": render(seed, "baseline", a.baseline, a),
            "variant": render(seed, "variant", a.variant, a),
        }

    # An incomplete render set must never be quietly presented as a smaller experiment. A crashed
    # render previously produced 5 sheets for an N=6 pre-registration, which would have been read as
    # "the test ran" when it did not. Refuse instead.
    missing = [(s, arm) for s in seeds for arm in ("baseline", "variant")
               if not rendered[s][arm].is_file()]
    if missing:
        log("")
        log("INCOMPLETE: %d render(s) missing: %s" % (len(missing), missing))
        for s, arm in missing:
            mf = pathlib.Path(a.out_root) / arm / ("seed-%d" % s) / "manifest.json"
            if mf.is_file():
                try:
                    item = list(json.loads(mf.read_text()).get("items", {}).values())[0]
                    log("   %s seed %d status: %s" % (arm, s, item.get("status")))
                except Exception:
                    pass
        log("REFUSING to build sheets: the pre-registered N was %d, not %d."
            % (len(seeds), len(seeds) - len({s for s, _ in missing})))
        return 5

    log("")
    log("axis check -- does the variant actually move the pixels?")
    stats, verdicts = {}, {}
    for seed in seeds:
        pb, pr = rendered[seed]["baseline"], rendered[seed]["variant"]
        if not (pb.is_file() and pr.is_file()):
            log("  seed %d: MISSING a render" % seed)
            verdicts[seed] = "missing"
            continue
        v, st = axis_bites(pb, pr)
        verdicts[seed] = v
        stats[seed] = st
        log("  seed %d: %-12s meanAbs=%.3f maxAbs=%d pct>8=%.2f%%" % (seed, v, st[0], st[1], st[2]))

    log("")
    log("building blinded sheets")
    rng = random.Random(a.blind_seed)
    key = {"experiment": a.label, "question": a.question, "axis": pf["changed"],
           "arm_baseline": {"workflow_sha256": pf["shas"]["baseline"]},
           "arm_variant": {"workflow_sha256": pf["shas"]["variant"]},
           "scene": a.scene, "scene_sha256": pf["scene_sha256"], "checkpoint": a.checkpoint,
           "seeds": seeds, "blinding_rng_seed": a.blind_seed,
           "decision_rule": a.decision_rule,
           "axis_check": {str(s): {"verdict": verdicts.get(s),
                                   "mean_abs": (stats.get(s) or (None,))[0],
                                   "pct_changed": (stats.get(s) or (None, None, None))[2]}
                          for s in seeds},
           "pairs": {}}
    built = 0
    for i, seed in enumerate(seeds, start=1):
        pb, pr = rendered[seed]["baseline"], rendered[seed]["variant"]
        if not (pb.is_file() and pr.is_file()):
            continue
        a_is_variant = rng.random() < 0.5
        dest = sheet(pb, pr, a_is_variant, i, a, root)
        built += 1
        key["pairs"]["pair-%02d" % i] = {
            "seed": seed,
            "A": "variant" if a_is_variant else "baseline",
            "B": "baseline" if a_is_variant else "variant",
            "sheet": str(dest),
            "sha256": {"A": hashlib.sha256((pr if a_is_variant else pb).read_bytes()).hexdigest(),
                       "B": hashlib.sha256((pb if a_is_variant else pr).read_bytes()).hexdigest()},
        }

    (root / "blinding-key.json").write_text(json.dumps(key, indent=2, sort_keys=True) + "\n")
    log("")
    log("sheets built: %d/%d   dir: %s" % (built, len(seeds), root / "pairs"))
    log("blinding key (do NOT show the founder): %s" % (root / "blinding-key.json"))
    if all(v == "identical" for v in verdicts.values() if v != "missing"):
        log("*** VACUOUS: every pair is pixel-identical. DO NOT ask for a ranking. ***")
        return 4
    return 0


if __name__ == "__main__":
    sys.exit(main())
