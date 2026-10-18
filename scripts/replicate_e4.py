#!/usr/bin/env python3
"""E4: does the hand-pass crop padding fix the arm composite? Two arms, 6 paired seeds, blinded.

Pre-registered in docs/experiment-backlog.md (E4) BEFORE any render here.

Arms are two WORKFLOW FILES, not an in-place edit -- so neither arm is ever mutated mid-sweep and
each carries its own sha256 into the blinding key. The harness refuses unless the two files differ
in exactly one leaf path (the one axis).

Guards carried over from E2/E3 (each is a mistake that already happened once):
  * REFUSES if the scene file contains an HTML comment -- the pipeline sends the raw file.
  * Substring checks normalise whitespace first (the scene wraps; the bare word `front` collides).
  * The frozen config is asserted in BOTH arms, so a silent drift cannot masquerade as an arm effect.
  * The card must be free before the first render.
  * Pillow is imported at module top ON PURPOSE: a missing Pillow aborts before the first render
    instead of wasting ~20 minutes and crashing at the sheet step.
  * Run with a PINNED interpreter:  /usr/bin/python3 scripts/replicate_e4.py
"""
import hashlib
import json
import pathlib
import random
import re
import subprocess
import sys
import time

from PIL import Image, ImageDraw, ImageFont

REPO = pathlib.Path("/home/tim/source/activity/turbo-carnival")
BASE_WF = REPO / "comfy_workflows/turbo_one_step_v2/step1_generate.json"
VAR_WF = REPO / "comfy_workflows/turbo_one_step_v2_e4_padding/step1_generate.json"
SCENE_FILE = REPO / "scenes/bedroom-front.txt"
SCENE = "bedroom-front"
CHECKPOINT = "CRPv18_PM40.safetensors"
ROOT = pathlib.Path(
    "/home/tim/Documents/obsidian/04 - projects/turbo-carnival/elo/e4-hand-padding-N6"
)
SEEDS = [20261201, 20261202, 20261203, 20261204, 20261205, 20261206]
BLINDING_RNG_SEED = 606060

ARM_BASE, ARM_RAISED = "baseline", "raised"
ARMS = ((ARM_BASE, BASE_WF), (ARM_RAISED, VAR_WF))
PAD_NODE = "66"
EXPECT_BASE_PAD, EXPECT_RAISED_PAD = 9.74609375, 48

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


def card_free():
    return subprocess.run(["pgrep", "-f", "tc_rend[e]r.py sweep"], capture_output=True).returncode != 0


def leaves(obj, prefix=""):
    if isinstance(obj, dict):
        for k, v in obj.items():
            yield from leaves(v, "%s.%s" % (prefix, k) if prefix else str(k))
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            yield from leaves(v, "%s[%d]" % (prefix, i))
    else:
        yield prefix, obj


def arm_checks(path, label, expect_pad):
    """Every frozen assertion, per arm. Returns (ok, dict)."""
    wf = json.loads(path.read_text())
    pos, neg = wf["88"]["inputs"]["text"], wf["79"]["inputs"]["text"]
    checks = {
        "positive has 1girl, solo": "1girl, solo" in pos,
        "negative has 2girls": "2girls" in neg,
        "negative has nipples": "nipples" in neg,
        "hand denoise >= 0.68": float(wf["113"]["inputs"]["denoise"]) >= 0.68,
        "face denoise == 0.66": abs(float(wf["110:109"]["inputs"]["denoise"]) - 0.66) < 1e-9,
        "flux tg LoRA off": wf["41"]["inputs"]["lora_3"].get("on") is False,
        "hand padding == %s" % expect_pad:
            abs(float(wf[PAD_NODE]["inputs"]["Value"]) - expect_pad) < 1e-6,
        "face feathering == 10": float(wf["20"]["inputs"]["feathering"]) == 10,
        "hand feathering == 10": float(wf["36"]["inputs"]["feathering"]) == 10,
        "blend_factor == 1 (both)": (float(wf["20"]["inputs"]["blend_factor"]) == 1
                                     and float(wf["36"]["inputs"]["blend_factor"]) == 1),
    }
    log("  %s:" % label)
    for k, v in checks.items():
        log("     %-28s %s" % (k, "ok" if v else "*** FAIL"))
    return all(checks.values()), {"sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def preflight():
    raw = SCENE_FILE.read_text()
    if "<!--" in raw:
        log("REFUSING: the scene file contains an HTML comment; the pipeline sends it raw.")
        return None
    body = norm(raw)
    if "never turned away" not in body:
        log("REFUSING: the scene file is not the validated front-facing scene.")
        return None

    log("preflight -- frozen config, per arm")
    ids = {}
    for label, path in ARMS:
        if not path.is_file():
            log("REFUSING: missing workflow %s (run scripts/e4_make_variant.py)" % path)
            return None
        ok, meta = arm_checks(path, label, EXPECT_BASE_PAD if label == ARM_BASE else EXPECT_RAISED_PAD)
        if not ok:
            log("REFUSING: the frozen config is not in place in the %s arm." % label)
            return None
        ids[label] = meta["sha256"]

    a, b = dict(leaves(json.loads(BASE_WF.read_text()))), dict(leaves(json.loads(VAR_WF.read_text())))
    diff = sorted(k for k in set(a) | set(b) if a.get(k, "<missing>") != b.get(k, "<missing>"))
    log("  one-axis check: %d changed leaf path(s)" % len(diff))
    for k in diff:
        log("     %s: %r -> %r" % (k, a.get(k), b.get(k)))
    if len(diff) != 1:
        log("REFUSING: the arms differ in %d leaves; that is not one axis." % len(diff))
        return None

    log("  scene chars (whitespace-normalised): %d" % len(body))
    return {"arms": ids, "scene_sha256": hashlib.sha256(SCENE_FILE.read_bytes()).hexdigest(),
            "changed_leaf": diff[0]}


def wait_for_card(max_minutes=20):
    for _ in range(max_minutes * 6):
        if card_free():
            return True
        time.sleep(10)
    return False


def render_seed_arm(seed, arm, workflow):
    out = ROOT / arm / ("seed-%d" % seed)
    out.mkdir(parents=True, exist_ok=True)
    cmd = [
        sys.executable, "bin/tc_render.py", "sweep",
        "--scene", SCENE,
        "--prompt-file", str(SCENE_FILE),
        "--out", str(out),
        "--checkpoints", CHECKPOINT,
        "--workflow", str(workflow),
        "--seed", str(seed),
        "--retries", "2",
    ]
    log("  %-8s seed=%d -> %s" % (arm, seed, out))
    p = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True)
    for line in [l for l in (p.stdout or "").strip().splitlines() if l.strip()][-2:]:
        log("      " + line)
    if p.returncode != 0:
        log("      rc=%s stderr=%s" % (p.returncode, (p.stderr or "")[-200:]))
    return out / ("%s__%s.png" % (SCENE, pathlib.Path(CHECKPOINT).stem))


def build_pair_sheet(path_a, path_b, a_is_raised, index):
    font, font_small = fonts()
    left = Image.open(path_a if not a_is_raised else path_b).convert("RGB")
    right = Image.open(path_b if not a_is_raised else path_a).convert("RGB")
    w, h = left.size
    sheet = Image.new("RGB", (MARGIN * 3 + w * 2, MARGIN * 2 + HEADER + h + FOOTER), (247, 247, 245))
    d = ImageDraw.Draw(sheet)
    d.text((MARGIN, MARGIN // 2 + 6), "PAIR %d  -  which do you prefer?" % index,
           fill=(20, 20, 20), font=font)
    top = MARGIN + HEADER
    sheet.paste(left, (MARGIN, top))
    sheet.paste(right, (MARGIN * 2 + w, top))
    d.text((MARGIN + w // 2 - 14, top - 34), "A", fill=(20, 20, 20), font=font)
    d.text((MARGIN * 2 + w + w // 2 - 14, top - 34), "B", fill=(20, 20, 20), font=font)
    d.text((MARGIN, top + h + 14), "pair %d" % index, fill=(110, 110, 110), font=font_small)
    pairs = ROOT / "pairs"
    pairs.mkdir(parents=True, exist_ok=True)
    dest = pairs / ("pair-%02d.png" % index)
    sheet.save(dest, optimize=True)
    return dest


def main():
    ROOT.mkdir(parents=True, exist_ok=True)
    log("interpreter: %s" % sys.executable)

    pf = preflight()
    if pf is None:
        return 2

    if not wait_for_card():
        log("REFUSING: the card never came free; not rendering a confounded set.")
        return 3

    log("")
    log("rendering 6 seeds x 2 arms (12 renders)")
    rendered = {}
    for seed in SEEDS:
        paths = {}
        for arm, wf in ARMS:
            paths[arm] = render_seed_arm(seed, arm, wf)
        rendered[seed] = paths
        log("      baseline=%s raised=%s" % (paths[ARM_BASE].is_file(), paths[ARM_RAISED].is_file()))

    log("")
    log("building blinded pair sheets")
    rng = random.Random(BLINDING_RNG_SEED)
    key = {
        "experiment": "E4-hand-crop-padding",
        "preregistered": "docs/experiment-backlog.md#E4",
        "question": "does raising the hand crop padding (node 66) fix the arm composite?",
        "axis": pf["changed_leaf"],
        "arm_baseline": {"padding": EXPECT_BASE_PAD, "workflow_sha256": pf["arms"][ARM_BASE]},
        "arm_raised": {"padding": EXPECT_RAISED_PAD, "workflow_sha256": pf["arms"][ARM_RAISED]},
        "frozen_elsewhere": "scene, checkpoint, denoise (hand 0.68 / face 0.66), feathering 10 (both), "
                            "blend_factor 1 (both), face padding (node 47) untouched",
        "scene": SCENE,
        "checkpoint": CHECKPOINT,
        "scene_sha256": pf["scene_sha256"],
        "seeds": SEEDS,
        "blind": "A/B randomised per pair; founder sees pairs/*.png only",
        "blinding_rng_seed": BLINDING_RNG_SEED,
        "decision_rule": "one-sided sign test, H1 = RAISED preferred; 6/6 -> p=0.015625 rejects; "
                         "5/6 -> p=0.109375 no measurable preference; a declared tie is a "
                         "NON-preference and does not count toward the numerator; a failed "
                         "one-sided test does NOT license the mirror claim; N is not extended",
        "preregistered_fallback": "if raised does not win, the padding mechanism is dead for this "
                                  "symptom; next candidates in order: (a) GrowMaskWithBlur node 29 "
                                  "(expand 20 / blur_radius 7.8), which moves the mask bbox and hence "
                                  "the crop; (b) feathering (10 in BOTH blends -> needs a two-node "
                                  "edit, so it requires a face+hand pairing to stay one axis)",
        "pairs": {},
    }
    built = 0
    for i, seed in enumerate(SEEDS, start=1):
        pb, pr = rendered[seed][ARM_BASE], rendered[seed][ARM_RAISED]
        if not (pb.is_file() and pr.is_file()):
            log("  pair %d: MISSING a render, skipped" % i)
            continue
        a_is_raised = rng.random() < 0.5
        dest = build_pair_sheet(pb, pr, a_is_raised, i)
        built += 1
        key["pairs"]["pair-%02d" % i] = {
            "seed": seed,
            "A": ARM_RAISED if a_is_raised else ARM_BASE,
            "B": ARM_BASE if a_is_raised else ARM_RAISED,
            "sheet": str(dest),
            "sha256": {"A": hashlib.sha256((pr if a_is_raised else pb).read_bytes()).hexdigest(),
                       "B": hashlib.sha256((pb if a_is_raised else pr).read_bytes()).hexdigest()},
        }
        log("  pair %d: %s  (A=%s) <- withheld" % (i, dest.name, key["pairs"]["pair-%02d" % i]["A"]))

    (ROOT / "blinding-key.json").write_text(json.dumps(key, indent=2, sort_keys=True) + "\n")
    log("")
    log("sheets built: %d/6   dir: %s" % (built, ROOT / "pairs"))
    log("blinding key (do NOT show the founder): %s" % (ROOT / "blinding-key.json"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
