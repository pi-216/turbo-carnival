#!/usr/bin/env python3
"""Render a fixed-scene / varied-checkpoint sweep from a versioned workflow.

WHY THIS EXISTS
---------------
The comparison pool is the instrument, and a pool is only meaningful if its items
vary along the ONE axis being ranked (see the elo-picker house rules). So a
checkpoint sweep must hold the SCENE and the SEED fixed and vary ONLY the base
model -- otherwise the ranking resolves scene luck or seed luck, not the
checkpoint.

This tool builds that batch: one render per checkpoint at one scene, all on ONE
shared seed, named `<scene>__<checkpoint>.png` so the leaderboard reads without a
side table, with a `manifest.json` in the pool directory recording pool-file ->
variant -> checkpoint -> prompt -> workflow -> seed (a Project stores only
paths/bytes, so without the manifest the mapping is lost).

It is deliberately NOT the Rails path. Growth::ContentGenerator renders and
schedules POSTS; this renders CANDIDATES for a comparison pool, which is a
different job. Same workflow file, same ComfyUI, different consumer.

USAGE
-----
    python3 bin/tc_render.py status
    python3 bin/tc_render.py checkpoints
    python3 bin/tc_render.py sweep --scene street --prompt "..." --out DIR \
        --checkpoints CRPv18_PM25.safetensors,Pornmaster_v2551619.safetensors \
        [--seed N] [--retries 2]

The seed is SHARED across every checkpoint in a sweep on purpose; rotate it per
sweep. Never let seed luck enter a pool that is ranking something else.
"""
import argparse
import hashlib
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

COMFY = "http://127.0.0.1:8188"
TOKEN_RE = r"{{%s}}"


class RenderFailed(RuntimeError):
    """One checkpoint failed after its retries.

    Raised PER CHECKPOINT rather than exiting, so a base model that cannot render
    cannot kill the batch -- a failing checkpoint is a finding about the APPROVED
    SET, not an error in the run. (Measured 2026-10-18: the two cyber* checkpoints
    fail with a Dynamo/torch.compile 'fake tensor call' error while the other
    three render fine.)
    """

# The approved base set -- mirrors PipelineCheckpointAllowlist::ALLOWED and
# /mnt/nas-ai-models/checkpoints/pony/. Keep the three in step.
CHECKPOINTS = [
    "CRPv18_PM25.safetensors",
    "CRPv18_PM40.safetensors",
    "Pornmaster_v2551619.safetensors",
    "cyberrealisticPony_v180Coreshift.safetensors",
    "cyberrealisticponyV85.TgCf.safetensors",
]
CHECKPOINT_DIR = "pony"


def get(path, timeout=30):
    with urllib.request.urlopen(f"{COMFY}{path}", timeout=timeout) as r:
        return json.load(r)


def post(path, payload, timeout=60):
    req = urllib.request.Request(
        f"{COMFY}{path}",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def download(filename, subfolder, kind, dest):
    q = urllib.parse.urlencode({"filename": filename, "subfolder": subfolder, "type": kind})
    with urllib.request.urlopen(f"{COMFY}/view?{q}", timeout=300) as r:
        data = r.read()
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(data)
    return dest


def substitute(obj, values):
    """Replace {{token}} in the workflow's string leaves.

    A leaf that IS exactly a token takes the token's native type (so auto_seed
    lands as a JSON number, not a string); a token embedded in a longer string is
    replaced textually. Mirrors BuildJobPayload, but type-aware -- the Rails path
    only ever emits string literals, which is why {{auto_seed}} there must be
    sent as a bare "{{auto_seed}}" string.

    A None value is a BUG, never a substitution: it serialises to JSON null and
    the node stringifies it to the literal text "None", which then renders as if
    the token had been removed. That failure is silent in the output image, so it
    fails here instead. (Cost a whole render batch on 2026-10-18.)
    """
    if isinstance(obj, dict):
        return {k: substitute(v, values) for k, v in obj.items()}
    if isinstance(obj, list):
        return [substitute(v, values) for v in obj]
    if isinstance(obj, str):
        for key, val in values.items():
            tok = "{{%s}}" % key
            if obj == tok or tok in obj:
                if val is None:
                    raise ValueError(
                        f"token {tok} resolved to None -- refusing to substitute; "
                        f"ComfyUI would render the literal string 'None'"
                    )
                if obj == tok:
                    return val
                obj = obj.replace(tok, str(val))
        return obj
    return obj


def find_output(history_entry):
    """Pull the saved image out of a /history entry's outputs."""
    for _node_id, out in (history_entry.get("outputs") or {}).items():
        for img in out.get("images", []) or []:
            return img.get("filename"), img.get("subfolder", ""), img.get("type", "output")
    return None, None, None


def cmd_status(_args):
    try:
        stats = get("/system_stats", timeout=10)
    except Exception as e:  # noqa: BLE001 - surface any transport failure plainly
        print(f"ComfyUI unreachable at {COMFY}: {e}")
        return 1
    dev = (stats.get("devices") or [{}])[0]
    print(f"ComfyUI up at {COMFY}")
    print(f"  device: {dev.get('name')}")
    free = dev.get("vram_free")
    total = dev.get("vram_total")
    if free is not None and total is not None:
        print(f"  vram:   {free / 2**30:.2f} GiB free of {total / 2**30:.2f} GiB")
    try:
        q = get("/queue", timeout=10)
        print(f"  queue:  running={len(q.get('queue_running', []))} pending={len(q.get('queue_pending', []))}")
    except Exception:  # noqa: BLE001
        pass
    return 0


def cmd_checkpoints(_args):
    """Validate the approved set against what ComfyUI actually publishes.

    House rule: a pool member with no usable VAE passes config and then fails at
    DECODE, after the model load. Probe before admitting a checkpoint.
    """
    names = get("/object_info/CheckpointLoaderSimple")["CheckpointLoaderSimple"]["input"]["required"]["ckpt_name"][0]
    print(f"ComfyUI publishes {len(names)} checkpoints")
    bad = 0
    for want in CHECKPOINTS:
        full = f"{CHECKPOINT_DIR}/{want}"
        ok = full in names
        bad += 0 if ok else 1
        print(f"  {'OK  ' if ok else 'MISS'} {full}")
    if bad:
        print(f"\n{bad} approved checkpoint(s) NOT published -- a sweep would fail mid-render.")
        return 1
    print("\nall approved checkpoints resolve")
    return 0


def render_one(workflow_path, prompt, checkpoint, out_path, seed, run_name, retries):
    if not prompt:
        raise SystemExit(
            "render_one called with an empty prompt -- the scene would never reach the "
            "model (this is the bug that emptied a whole batch on 2026-10-18)"
        )
    values = {
        "prompt": prompt,
        "checkpoint": f"{CHECKPOINT_DIR}/{checkpoint}",
        "run_name": run_name,
        "auto_seed": int(seed),
        "job_id": int(seed),
    }
    wf = substitute(json.loads(Path(workflow_path).read_text()), values)

    attempt = 0
    while True:
        attempt += 1
        try:
            res = post("/prompt", {"prompt": wf})
            pid = res["prompt_id"]
        except urllib.error.HTTPError as e:
            raise RenderFailed(f"submit rejected: {e.code} {e.read().decode()[:300]}")

        started = time.time()
        entry = None
        while time.time() - started < 1800:
            time.sleep(10)
            hist = get(f"/history/{pid}", timeout=30)
            if pid in hist:
                entry = hist[pid]
                break

        if entry is None:
            raise RenderFailed(f"timed out waiting for {pid} after 30 min")

        status = (entry.get("status") or {})
        if status.get("status_str") == "success":
            fn, sub, kind = find_output(entry)
            if not fn:
                raise RenderFailed(f"{pid}: success but no image output recorded")
            download(fn, sub, kind, Path(out_path))
            secs = int(time.time() - started)
            print(f"  {checkpoint:<44} -> {Path(out_path).name}  ({secs}s)")
            return Path(out_path)

        # A single OOM that succeeds on retry is known behaviour on this card
        # (~23 GB of 24 GB peak); more than one failure is a real error.
        msgs = [m for m in status.get("messages", []) if m and m[0] in ("execution_error", "execution_interrupted")]
        detail = ""
        for m in msgs:
            if len(m) > 1 and isinstance(m[1], dict):
                detail = m[1].get("exception_message", "")[:200]
        print(f"  {checkpoint:<44} attempt {attempt} failed: {detail or status.get('status_str')}")
        if attempt > retries:
            raise RenderFailed(f"failed after {attempt} attempts: {detail or status.get('status_str')}")
        time.sleep(15)


def cmd_sweep(args):
    workflow = Path(args.workflow)
    if not workflow.is_file():
        raise SystemExit(f"no such workflow file: {workflow}")

    prompt = Path(args.prompt_file).read_text().strip() if args.prompt_file else (args.prompt or "")
    if not prompt:
        raise SystemExit("give --prompt or --prompt-file")

    if args.checkpoints.strip().lower() == "all":
        checkpoints = CHECKPOINTS
    else:
        checkpoints = [c.strip() for c in args.checkpoints.split(",") if c.strip()]
    for c in checkpoints:
        if c not in CHECKPOINTS:
            raise SystemExit(
                f"checkpoint {c!r} is not in the approved set:\n  " + "\n  ".join(CHECKPOINTS)
            )

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    seed = args.seed
    if seed is None:
        seed = int(time.time()) % 2_147_483_646
    print(f"scene={args.scene} seed={seed} (shared across every checkpoint) checkpoints={len(checkpoints)}")
    print(f"prompt[{len(prompt)} chars]: {prompt[:90]}...")

    manifest_path = out_dir / "manifest.json"
    manifest = json.loads(manifest_path.read_text()) if manifest_path.is_file() else {}
    manifest.update({
        "scene": args.scene,
        "prompt": prompt,
        "seed": seed,
        "workflow": str(workflow),
        "workflow_sha256": hashlib.sha256(workflow.read_bytes()).hexdigest(),
        "rendered_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    })
    entries = manifest.setdefault("items", {})

    for c in checkpoints:
        stem = Path(c).stem
        dest = out_dir / f"{args.scene}__{stem}.png"
        if dest.is_file() and not args.force:
            print(f"  {c:<44} -> {dest.name}  (exists, skipped)")
            status = 'skipped'
        else:
            try:
                render_one(workflow, prompt, c, dest, seed, args.scene, args.retries)
                status = 'ok'
            except RenderFailed as e:
                # Continue: a checkpoint that cannot render is a result, not a crash.
                print(f"  {c:<44} FAILED -- {e}")
                status = f'failed -- {e}'
        entries[dest.name] = {
            "checkpoint": f"{CHECKPOINT_DIR}/{c}",
            "scene": args.scene,
            "seed": seed,
            "status": status,
            "sha256": hashlib.sha256(dest.read_bytes()).hexdigest() if dest.is_file() else None,
        }
        manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")

    ok = [n for n, v in entries.items() if v.get('status') == 'ok']
    bad = [n for n, v in entries.items() if str(v.get('status', '')).startswith('failed')]
    print(f"\npool dir: {out_dir}")
    print(f"manifest: {manifest_path}")
    print(f"rendered: {len(ok)}  failed: {len(bad)}  total: {len(entries)}")
    for n in bad:
        print(f"  FAILED {n}: {entries[n]['status']}")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("status", help="is ComfyUI up, and how busy is it").set_defaults(func=cmd_status)
    sub.add_parser("checkpoints", help="validate the approved set against ComfyUI").set_defaults(func=cmd_checkpoints)

    s = sub.add_parser("sweep", help="render one scene across several checkpoints on one shared seed")
    s.add_argument("--scene", required=True, help="group name; becomes the filename prefix")
    s.add_argument("--prompt", help="the scene text substituted for {{prompt}}")
    s.add_argument("--prompt-file", help="read the scene text from a file (overrides --prompt)")
    s.add_argument("--out", required=True, help="pool directory (the elo-picker project folder)")
    s.add_argument("--checkpoints", default="all", help="'all' or a comma-separated subset of the approved set")
    s.add_argument("--workflow", default="comfy_workflows/turbo_one_step_v2/step1_generate.json")
    s.add_argument("--seed", type=int, default=None, help="shared seed; omit to pick one")
    s.add_argument("--retries", type=int, default=2, help="retries per render (OOM-first-try is known)")
    s.add_argument("--force", action="store_true", help="re-render even if the PNG exists")
    s.set_defaults(func=cmd_sweep)

    args = ap.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()
