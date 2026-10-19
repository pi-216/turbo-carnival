"""E2 replication: PM25 vs PM40 across 6 paired seeds, BLINDED.

Pre-registered in docs/experiment-backlog.md (E2) before any render here.

Why this exists: the founder judged one matched pair ("I think she looks slightly better in
PM25, but it's too small a sample"). A single pair cannot separate a real checkpoint
preference from one pair's luck, and ranking `...__CRPv18_PM25.png` against
`...__CRPv18_PM40.png` is not blind to his own stated prior. So: more pairs, and the labels
withheld.

What it does
  1. Waits for the FROZEN config (node 113 hand denoise == 0.68, i.e. the deltas applied) and
     for the card to be free, so no render here is confounded by a mid-run config change.
  2. Renders 6 fresh seeds x 2 checkpoints into <root>/seed-<N>/  --  per-seed dirs, because
     the pool filename (`{scene}__{stem}.png`) carries no seed and would otherwise collide
     ("exists, skipped").
  3. Builds one blinded side-by-side sheet per pair in <root>/pairs/, labelled only A | B.
  4. Writes the blinding key to <root>/blinding-key.json, kept back from the founder until the
     ranking is done.

Seeds are FRESH. The already-judged seed 20261018 is deliberately excluded so that every pair
is new to him and therefore every pair is genuinely blind. Six sequential seeds, so the set is
visibly not cherry-picked.

Decision rule (fixed in the pre-registration, before results): one-sided sign test over the 6
pairs; 6/6 for PM25 rejects at p = 0.031, 5/6 does not (p = 0.109).

INVOCATION -- run with a PINNED absolute interpreter:

    /usr/bin/python3 scripts/replicate_pm25_vs_pm40.py

A backgrounded job can resolve a DIFFERENT `python3` than the foreground shell does; this
machine has five on PATH and one of them is a Pillow-less Homebrew 3.15. That is how the first
attempt died on `ModuleNotFoundError: PIL`.

Note the failure mode is benign *because* Pillow is imported at module top level: a missing
Pillow aborts the run BEFORE the first render, so no card time is wasted. Do NOT move the
import down into the sheet step -- that would convert a free, immediate failure into 40 minutes
of renders followed by a crash at the very last step.
"""
import json
import pathlib
import random
import subprocess
import sys
import time

from PIL import Image, ImageDraw, ImageFont

REPO = pathlib.Path("/home/tim/source/activity/turbo-carnival")
WORKFLOW = REPO / "comfy_workflows/turbo_one_step_v2/step1_generate.json"
SCENE_FILE = REPO / "scenes/kitchen-apron.txt"
SCENE = "kitchen-apron"

ROOT = pathlib.Path(
    "/home/tim/Documents/obsidian/04 - projects/turbo-carnival/elo/kitchen-apron-pm25-vs-pm40-N6"
)
CP_A = "CRPv18_PM25.safetensors"
CP_B = "CRPv18_PM40.safetensors"

SEEDS = [20261019, 20261020, 20261021, 20261022, 20261023, 20261024]
BLINDING_RNG_SEED = 424242

GAP = 28
MARGIN = 28
HEADER = 76
FOOTER = 56

try:
    FONT = ImageFont.load_default(size=34)
    FONT_SMALL = ImageFont.load_default(size=26)
except TypeError:  # older Pillow: no size kwarg
    FONT = ImageFont.load_default()
    FONT_SMALL = FONT


def log(msg):
    print(msg, flush=True)


def runtime_denoise():
    """Current hand-inpaint denoise from the workflow file (the frozen-config probe)."""
    try:
        wf = json.loads(WORKFLOW.read_text())
        return wf["113"]["inputs"].get("denoise")
    except Exception:
        return None


def sweep_running():
    return subprocess.run(
        ["pgrep", "-f", "tc_rend[e]r.py sweep"], capture_output=True
    ).returncode == 0


def wait_for_frozen_config(max_minutes=150):
    deadline = time.time() + max_minutes * 60
    announced = False
    while time.time() < deadline:
        d = runtime_denoise()
        if d is not None and float(d) >= 0.68 and not sweep_running():
            log(f"  frozen config detected (hand denoise={d}), card free")
            return True
        if not announced:
            log(f"  waiting for the deltas to land (hand denoise currently {d}) ...")
            announced = True
        time.sleep(15)
    log("  TIMEOUT waiting for the frozen config; refusing to render a confounded set")
    return False


def render_seed(seed):
    out = ROOT / f"seed-{seed}"
    out.mkdir(parents=True, exist_ok=True)
    cmd = [
        sys.executable, "bin/tc_render.py", "sweep",
        "--scene", SCENE,
        "--prompt-file", str(SCENE_FILE),
        "--out", str(out),
        "--checkpoints", f"{CP_A},{CP_B}",
        "--seed", str(seed),
        "--retries", "2",
    ]
    log(f"  render seed={seed} -> {out.name}")
    p = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True)
    tail = [l for l in (p.stdout or "").strip().splitlines() if l.strip()][-4:]
    for l in tail:
        log("      " + l)
    if p.returncode != 0:
        log(f"      rc={p.returncode} stderr={ (p.stderr or '')[-300:] }")
    return out


def build_pair_sheet(seed, path_a, path_b, secret_a_is_pm25, index):
    """One sheet per pair: left=A, right=B. Nothing on the sheet names a checkpoint."""
    left = Image.open(path_a if secret_a_is_pm25 else path_b).convert("RGB")
    right = Image.open(path_b if secret_a_is_pm25 else path_a).convert("RGB")
    w, h = left.size
    width = MARGIN * 3 + w * 2
    height = MARGIN * 2 + HEADER + h + FOOTER
    sheet = Image.new("RGB", (width, height), (247, 247, 245))
    d = ImageDraw.Draw(sheet)

    d.text((MARGIN, MARGIN // 2 + 6), f"PAIR {index}  -  which do you prefer?",
           fill=(20, 20, 20), font=FONT)
    top = MARGIN + HEADER
    sheet.paste(left, (MARGIN, top))
    sheet.paste(right, (MARGIN * 2 + w, top))
    d.text((MARGIN + w // 2 - 14, top - 34), "A", fill=(20, 20, 20), font=FONT)
    d.text((MARGIN * 2 + w + w // 2 - 14, top - 34), "B", fill=(20, 20, 20), font=FONT)
    d.text((MARGIN, top + h + 14), f"pair {index}", fill=(110, 110, 110), font=FONT_SMALL)

    pairs_dir = ROOT / "pairs"
    pairs_dir.mkdir(parents=True, exist_ok=True)
    dest = pairs_dir / f"pair-{index:02d}.png"
    sheet.save(dest, optimize=True)
    return dest


def main():
    ROOT.mkdir(parents=True, exist_ok=True)

    if not wait_for_frozen_config():
        return 2

    log("")
    log("rendering 6 paired seeds x 2 checkpoints (12 renders, ~3 min each)")
    rendered = {}
    for seed in SEEDS:
        out = render_seed(seed)
        pa = out / f"{SCENE}__{pathlib.Path(CP_A).stem}.png"
        pb = out / f"{SCENE}__{pathlib.Path(CP_B).stem}.png"
        rendered[seed] = (pa, pb)
        log(f"      A={pa.is_file()} B={pb.is_file()}")

    log("")
    log("building blinded pair sheets")
    rng = random.Random(BLINDING_RNG_SEED)
    key = {
        "experiment": "E2-pm25-vs-pm40",
        "preregistered": "docs/experiment-backlog.md#E2",
        "scene": SCENE,
        "blind": "A/B assignment randomised per pair; founders sees pairs/*.png only",
        "blinding_rng_seed": BLINDING_RNG_SEED,
        "checkpoint_pm25": CP_A,
        "checkpoint_pm40": CP_B,
        "decision_rule": "one-sided sign test, 6/6 for PM25 rejects at p=0.031; 5/6 does not (p=0.109)",
        "pairs": {},
    }
    sheets = []
    for i, seed in enumerate(SEEDS, start=1):
        pa, pb = rendered[seed]
        if not (pa.is_file() and pb.is_file()):
            log(f"  pair {i}: MISSING a render, skipped")
            continue
        a_is_pm25 = rng.random() < 0.5
        dest = build_pair_sheet(seed, pa, pb, a_is_pm25, i)
        sheets.append(dest)
        key["pairs"][f"pair-{i:02d}"] = {
            "seed": seed,
            "A": CP_A if a_is_pm25 else CP_B,
            "B": CP_B if a_is_pm25 else CP_A,
            "sheet": str(dest),
            "sha256": {
                "A": __import__("hashlib").sha256((pa if a_is_pm25 else pb).read_bytes()).hexdigest(),
                "B": __import__("hashlib").sha256((pb if a_is_pm25 else pa).read_bytes()).hexdigest(),
            },
        }
        log(f"  pair {i}: {dest.name}  ({'A=PM25' if a_is_pm25 else 'A=PM40'}) <- withheld from founder")

    (ROOT / "blinding-key.json").write_text(json.dumps(key, indent=2, sort_keys=True) + "\n")

    log("")
    log(f"sheets: {len(sheets)}  dir: {ROOT / 'pairs'}")
    log(f"blinding key (do NOT show the founder): {ROOT / 'blinding-key.json'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
