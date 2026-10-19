#!/usr/bin/env python3
"""E3 replication: PM25 vs PM40 on the VALIDATED front-facing scene. 6 paired seeds, blinded.

Supersedes E2, which was aborted for cause before any ranking (a wardrobe x pose interaction
produced naked-behind renders). Because E2 produced no ranking, this is the FIRST look at the
question, not a second pass -- that matters for the test's multiplicity.

Pre-registered in docs/experiment-backlog.md (E3) BEFORE any render here.

Guards carried over from the E2 postmortem -- each is a mistake that already happened once:
  * The pipeline sends the scene file RAW, so a scene file must be pure prompt text. This script
    REFUSES to run if the scene file contains an HTML comment: 1189 chars of design notes leaked
    in that way and rendered a kitchen inside a bedroom.
  * Substring checks normalise whitespace FIRST. The scene wraps across lines so
    "three-quarter front view" straddles a newline, and the bare word "front" also occurs in the
    older scene text ("the front of her torso"). Both have already produced a wrong answer.
  * The frozen config is asserted up front, so a silent drift cannot masquerade as a result.
  * Run with a PINNED interpreter:  /usr/bin/python3 scripts/replicate_e3.py

Pillow is imported at module top level ON PURPOSE: a missing Pillow then aborts before the first
render, instead of wasting ~14 minutes and crashing at the sheet step. Do not move it down.
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
WORKFLOW = REPO / "comfy_workflows/turbo_one_step_v2/step1_generate.json"
SCENE_FILE = REPO / "scenes/bedroom-front.txt"
SCENE = "bedroom-front"
ROOT = pathlib.Path(
    "/home/tim/Documents/obsidian/04 - projects/turbo-carnival/elo/bedroom-front-pm25-vs-pm40-N6"
)
CP_A = "CRPv18_PM25.safetensors"
CP_B = "CRPv18_PM40.safetensors"
SEEDS = [20261101, 20261102, 20261103, 20261104, 20261105, 20261106]
BLINDING_RNG_SEED = 515151

MARGIN, HEADER, FOOTER = 28, 76, 56
CELL_W = 816


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


def preflight():
    """Refuse to render unless the scene and the frozen config are exactly right."""
    raw = SCENE_FILE.read_text()
    if "<!--" in raw:
        log("REFUSING: the scene file contains an HTML comment.")
        log("  The pipeline sends the raw file, so those notes WOULD become prompt text.")
        log("  Move them to docs/scene-notes-*.md and re-run.")
        return None

    body = norm(raw)
    if "never turned away" not in body:
        log("REFUSING: the scene file is not the validated front-facing scene.")
        return None

    wf = json.loads(WORKFLOW.read_text())
    pos, neg = wf["88"]["inputs"]["text"], wf["79"]["inputs"]["text"]
    checks = {
        "scene has no HTML comment": True,
        "scene is front-facing": True,
        "positive has 1girl, solo": "1girl, solo" in pos,
        "negative has 2girls": "2girls" in neg,
        "negative has nipples": "nipples" in neg,
        "hand denoise >= 0.68": float(wf["113"]["inputs"]["denoise"]) >= 0.68,
        "face denoise == 0.66": abs(float(wf["110:109"]["inputs"]["denoise"]) - 0.66) < 1e-9,
        "flux tg LoRA off": wf["41"]["inputs"]["lora_3"].get("on") is False,
    }
    log("preflight:")
    for k, v in checks.items():
        log("  %-30s %s" % (k, "ok" if v else "*** FAIL"))
    if not all(checks.values()):
        log("REFUSING: the frozen config is not in place.")
        return None

    log("  scene chars (whitespace-normalised): %d" % len(body))
    return {
        "workflow_sha256": hashlib.sha256(WORKFLOW.read_bytes()).hexdigest(),
        "scene_sha256": hashlib.sha256(SCENE_FILE.read_bytes()).hexdigest(),
        "scene_chars": len(body),
    }


def wait_for_card(max_minutes=20):
    for _ in range(max_minutes * 6):
        if card_free():
            return True
        time.sleep(10)
    return False


def render_seed(seed):
    out = ROOT / f"seed-{seed}"
    out.mkdir(parents=True, exist_ok=True)
    cmd = [
        sys.executable, "bin/tc_render.py", "sweep",
        "--scene", SCENE,
        "--prompt-file", str(SCENE_FILE),
        "--out", str(out),
        "--checkpoints", "%s,%s" % (CP_A, CP_B),
        "--seed", str(seed),
        "--retries", "2",
    ]
    log("  render seed=%s -> %s" % (seed, out.name))
    p = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True)
    for line in [l for l in (p.stdout or "").strip().splitlines() if l.strip()][-3:]:
        log("      " + line)
    if p.returncode != 0:
        log("      rc=%s stderr=%s" % (p.returncode, (p.stderr or "")[-200:]))
    return out


def build_pair_sheet(path_a, path_b, a_is_pm25, index):
    font, font_small = fonts()
    left = Image.open(path_a if a_is_pm25 else path_b).convert("RGB")
    right = Image.open(path_b if a_is_pm25 else path_a).convert("RGB")
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
    log("rendering 6 paired seeds x 2 checkpoints (12 renders)")
    rendered = {}
    for seed in SEEDS:
        out = render_seed(seed)
        pa = out / ("%s__%s.png" % (SCENE, pathlib.Path(CP_A).stem))
        pb = out / ("%s__%s.png" % (SCENE, pathlib.Path(CP_B).stem))
        rendered[seed] = (pa, pb)
        log("      A=%s B=%s" % (pa.is_file(), pb.is_file()))

    log("")
    log("building blinded pair sheets")
    rng = random.Random(BLINDING_RNG_SEED)
    key = {
        "experiment": "E3-pm25-vs-pm40-on-validated-scene",
        "preregistered": "docs/experiment-backlog.md#E3",
        "scene": SCENE,
        "blind": "A/B randomised per pair; founder sees pairs/*.png only",
        "blinding_rng_seed": BLINDING_RNG_SEED,
        "checkpoint_pm25": CP_A,
        "checkpoint_pm40": CP_B,
        "seeds": SEEDS,
        "decision_rule": "one-sided sign test; 6/6 -> p=0.0156 rejects; 5/6 -> p=0.109 does not",
        "frozen_workflow_sha256": pf["workflow_sha256"],
        "scene_sha256": pf["scene_sha256"],
        "pairs": {},
    }
    built = 0
    for i, seed in enumerate(SEEDS, start=1):
        pa, pb = rendered[seed]
        if not (pa.is_file() and pb.is_file()):
            log("  pair %d: MISSING a render, skipped" % i)
            continue
        a_is_pm25 = rng.random() < 0.5
        dest = build_pair_sheet(pa, pb, a_is_pm25, i)
        built += 1
        key["pairs"]["pair-%02d" % i] = {
            "seed": seed,
            "A": CP_A if a_is_pm25 else CP_B,
            "B": CP_B if a_is_pm25 else CP_A,
            "sheet": str(dest),
            "sha256": {
                "A": hashlib.sha256((pa if a_is_pm25 else pb).read_bytes()).hexdigest(),
                "B": hashlib.sha256((pb if a_is_pm25 else pa).read_bytes()).hexdigest(),
            },
        }
        log("  pair %d: %s  (A=%s) <- withheld" % (i, dest.name, "PM25" if a_is_pm25 else "PM40"))

    (ROOT / "blinding-key.json").write_text(json.dumps(key, indent=2, sort_keys=True) + "\n")
    log("")
    log("sheets built: %d/6   dir: %s" % (built, ROOT / "pairs"))
    log("blinding key (do NOT show the founder): %s" % (ROOT / "blinding-key.json"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
