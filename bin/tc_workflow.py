#!/usr/bin/env python3
"""Inspect the ComfyUI workflows stored in pipeline_steps.comfy_workflow_json.

WHY THIS EXISTS
---------------
A render workflow is not a file in this repo -- it is a TEXT column in Postgres
(`pipeline_steps.comfy_workflow_json`), and it reaches ComfyUI only after three
separate substitution passes (BuildJobPayload -> PipelinePromptSafety ->
SubmitJob). So answering "what does turbo-one-step actually render with?" means
reading the database, not the filesystem, and the answer is buried in a ~75-node
graph where only a handful of nodes matter.

This tool makes that legible: it lists the model files a workflow loads, the
placeholders it expects, the sampler/resolution it runs at, and -- with --diff
-- what differs between two steps. Read-only: it never writes to the DB, never
talks to ComfyUI, and never touches a workflow.

USAGE
-----
    python3 bin/tc_workflow.py 39            # one step
    python3 bin/tc_workflow.py 39 40         # several
    python3 bin/tc_workflow.py 39 40 --diff  # + a node-by-node difference
    python3 bin/tc_workflow.py --file wf.json
    python3 bin/tc_workflow.py --steps       # inventory of every stored step

The placeholders listed here are the {{token}} forms the workflow expects. Note
that {{auto_seed}} and {{job_id}} are resolved by SubmitJob and only match the
QUOTED JSON form ("{{auto_seed}}") -- a token embedded inside a longer string is
silently left literal.
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

DB = "turbo_carnival_development"
TOKEN_RE = re.compile(r"\{\{([A-Za-z0-9_]+)\}\}")

# Loader input names that name a file on disk. Keyed generically by input name so
# a node class we have never seen still gets reported rather than skipped.
MODEL_KEYS = {
    "ckpt_name", "unet_name", "lora_name", "lora", "vae_name", "clip_name",
    "clip_name1", "clip_name2", "clip_name3", "clip_name4",
    "control_net_name", "ipadapter_file", "model_name", "style_model_name",
    "upscale_model_name", "clip_vision_name", "gligen_name", "photomaker_model_name",
    "instantid_file", "insightface", "sams_model_name", "sam_model_name",
    "detector_name", "bbox_detector", "pose_estimator", "face_restore_model",
    "embedding_name", "text_encoder", "audio_vae", "vocoder",
}
WEIGHT_KEYS = {"strength_model", "strength_clip", "weight", "weight_dtype"}
# Nodes whose scalar inputs describe HOW the render runs.
SAMPLER_KEYS = {"steps", "cfg", "sampler_name", "scheduler", "denoise",
                "start_at_step", "end_at_step", "add_noise", "return_with_leftover_noise"}
LATENT_KEYS = {"width", "height", "batch_size", "length"}


def fetch_steps(step_ids):
    """Return {step_id: (pipeline_id, name, workflow_dict)} for the given ids.

    The workflow column is arbitrary MULTI-LINE text -- the file loaded into it may
    be pretty-printed -- so a line-oriented read silently cuts a row in half.
    Observed 2026-10-18 as a JSONDecodeError on a step whose file was pretty. Rows
    are delimited with sentinel control characters instead of newlines.
    """
    ids = ",".join(str(int(s)) for s in step_ids)
    sql = (
        "select E'\\x01' || id || E'\\x02' || pipeline_id || E'\\x02' || name "
        "|| E'\\x02' || comfy_workflow_json || E'\\x01' "
        f"from pipeline_steps where id in ({ids}) order by pipeline_id, \"order\";"
    )
    out = subprocess.run(
        ["psql", "-d", DB, "-At", "-c", sql],
        capture_output=True, text=True, check=True,
    ).stdout
    result = {}
    for chunk in out.split("\x01"):
        if not chunk.strip():
            continue
        sid, pid, name, raw = chunk.split("\x02", 3)
        result[int(sid)] = (int(pid), name, json.loads(raw))
    return result


def fetch_inventory():
    sql = (
        "select pipeline_id||'/'||id||' '||name||' -> '||"
        "coalesce((select string_agg(distinct m[1],',') from "
        "regexp_matches(comfy_workflow_json,'\\{\\{([A-Za-z0-9_]+)\\}\\}','g') m),"
        "'(none)') from pipeline_steps order by pipeline_id, \"order\";"
    )
    return subprocess.run(
        ["psql", "-d", DB, "-At", "-c", sql], capture_output=True, text=True, check=True
    ).stdout


def walk(node_inputs, prefix=""):
    """Yield (path, value) for every scalar leaf under a node's inputs."""
    for key, val in node_inputs.items():
        path = f"{prefix}.{key}" if prefix else key
        if isinstance(val, dict):
            yield from walk(val, path)
        elif isinstance(val, list):
            for i, item in enumerate(val):
                if isinstance(item, (dict, list)):
                    yield from walk({"": item}, f"{path}[{i}]")
                else:
                    yield f"{path}[{i}]", item
        else:
            yield path, val


def summarise(step_id, pipeline_id, name, wf, show_nodes=True):
    print(f"\n{'=' * 78}")
    print(f"step {step_id}  (pipeline {pipeline_id})  {name}   -- {len(wf)} nodes")
    print("=" * 78)

    models, samplers, latents, prompts, tokens = [], [], [], [], set()

    for nid, node in wf.items():
        if not isinstance(node, dict):
            continue
        ct = node.get("class_type", "?")
        title = (node.get("_meta") or {}).get("title", "")
        inputs = node.get("inputs", {})

        for path, val in walk(inputs):
            leaf = path.split(".")[-1].split("[")[0]
            if isinstance(val, str):
                tokens.update(TOKEN_RE.findall(val))
            if leaf in MODEL_KEYS and isinstance(val, str):
                models.append((nid, ct, leaf, val))
            if leaf in WEIGHT_KEYS and isinstance(val, (int, float)):
                models.append((nid, ct, leaf, val))
            if leaf in SAMPLER_KEYS:
                samplers.append((nid, ct, leaf, val))
            if leaf in LATENT_KEYS:
                latents.append((nid, ct, leaf, val))
            if leaf in ("text", "prompt") and isinstance(val, str) and val.strip():
                prompts.append((nid, ct, title, val))

    def block(label, rows, fmt):
        print(f"\n{label}")
        if not rows:
            print("  (none)")
            return
        for row in rows:
            print("  " + fmt(row))

    def nkey(row):
        # Node keys are JSON strings but can look numeric ("110:108"), so order
        # on the string form -- mixed int/str tuples are unorderable.
        return str(row[0])

    models = sorted(models, key=nkey)
    samplers = sorted(set(samplers), key=nkey)
    latents = sorted(set(latents), key=nkey)

    block("MODELS / WEIGHTS", models, lambda r: f"node {r[0]:>8}  {r[1]:<26} {r[2]:<16} = {r[3]}")
    block("SAMPLER", samplers, lambda r: f"node {r[0]:>8}  {r[1]:<26} {r[2]:<16} = {r[3]}")
    block("LATENT / RESOLUTION", latents, lambda r: f"node {r[0]:>8}  {r[1]:<26} {r[2]:<16} = {r[3]}")

    # Power Lora Loader (rgthree) keeps each slot in its own dict carrying an `on`
    # flag, and walk() flattens that dict away -- so reading only the strength
    # reports a DISABLED LoRA as though it were contributing. That misled a whole
    # batch decision on 2026-10-18 (three wardrobe LoRAs were off, not on). The
    # flag is reported here explicitly; a strength with on=false is inert.
    slots = []
    for nid, node in wf.items():
        if not isinstance(node, dict) or 'Power Lora Loader' not in (node.get('class_type') or ''):
            continue
        for key, val in (node.get('inputs') or {}).items():
            if isinstance(val, dict) and 'lora' in val:
                slots.append((nid, key, val.get('on'), val.get('strength'), val['lora']))

    print("\nLoRA SLOTS  (on=false => strength is INERT)")
    if not slots:
        print("  (none)")
    for nid, key, on, strength, lname in sorted(slots, key=lambda r: (str(r[0]), r[1])):
        print(f"  node {nid:>8} {key:<8} {'ON ' if on else 'off'} strength={str(strength):<6} {lname}")

    print("\nTEXT INPUTS")
    if not prompts:
        print("  (none)")
    for nid, ct, title, val in sorted(prompts, key=nkey):
        preview = val if len(val) <= 110 else val[:107] + "..."
        print(f"  node {nid:>8}  {ct:<26} {title[:22]:<22} {preview!r}")
        found = TOKEN_RE.findall(val)
        if found:
            print(f"{'':>38}     ^ placeholders: {found}")

    print(f"\nPLACEHOLDERS REQUIRED: {sorted(tokens) or '(none)'}")


def diff_steps(a, b):
    (apid, aname, awf), (bpid, bname, bwf) = a, b
    print(f"\n{'=' * 78}")
    print(f"DIFF  step {apid} ({aname})  vs  step {bpid} ({bname})")
    print("=" * 78)

    only_a = sorted(set(awf) - set(bwf), key=lambda k: int(k) if k.isdigit() else 0)
    only_b = sorted(set(bwf) - set(awf), key=lambda k: int(k) if k.isdigit() else 0)
    if only_a:
        print(f"only in {apid}: {only_a}")
    if only_b:
        print(f"only in {bpid}: {only_b}")

    shared = sorted(set(awf) & set(bwf), key=lambda k: int(k) if k.isdigit() else 0)
    changes = 0
    for nid in shared:
        na, nb = awf[nid], bwf[nid]
        if not isinstance(na, dict) or not isinstance(nb, dict):
            continue
        if na.get("class_type") != nb.get("class_type"):
            print(f"  node {nid}: class {na.get('class_type')} -> {nb.get('class_type')}")
            changes += 1
            continue
        da = dict(walk(na.get("inputs", {})))
        db = dict(walk(nb.get("inputs", {})))
        keys = sorted(set(da) | set(db))
        for k in keys:
            if da.get(k) != db.get(k):
                print(f"  node {nid} ({na.get('class_type')}) {k}: {da.get(k)!r} -> {db.get(k)!r}")
                changes += 1
    if not changes and not only_a and not only_b:
        print("  (identical on class_type + scalar inputs)")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("steps", nargs="*", type=int, help="pipeline_step ids")
    ap.add_argument("--file", help="read a workflow JSON file instead of the DB")
    ap.add_argument("--inventory", action="store_true", help="print the stored-step inventory and exit")
    ap.add_argument("--diff", action="store_true", help="diff the given steps (needs exactly 2)")
    ap.add_argument("--set", action="append", metavar="NODE.FIELD=VALUE",
                    help="set a scalar input on a node of the FIRST step (repeatable). "
                         "Used to build a parameterised variant, e.g. "
                         "'--set 87.ckpt_name={{checkpoint}}'")
    ap.add_argument("--export", metavar="PATH",
                    help="write the FIRST step's workflow (after --set) to PATH as pretty JSON")
    args = ap.parse_args()

    if args.inventory:
        print(fetch_inventory())
        return

    if args.file:
        with open(args.file) as fh:
            wf = json.load(fh)
        summarise("file", "-", args.file, wf)
        return

    if not args.steps:
        ap.error("give at least one step id, or --file, or --inventory")

    fetched = fetch_steps(args.steps)
    missing = set(args.steps) - set(fetched)
    if missing:
        print(f"warning: no such step id(s): {sorted(missing)}", file=sys.stderr)

    if args.set:
        target = args.steps[0]
        if target not in fetched:
            ap.error(f"--set needs a readable step id (got {target})")
        wf = fetched[target][2]
        for spec in args.set:
            node, _, rest = spec.partition(".")
            field, _, value = rest.partition("=")
            if not node or not field or not _:
                ap.error(f"bad --set spec {spec!r}; expected NODE.FIELD=VALUE")
            if node not in wf or "inputs" not in wf[node]:
                ap.error(f"no such node with inputs: {node} (step {target})")
            wf[node]["inputs"][field] = value
            print(f"set node {node}.{field} = {value!r}")

    for sid in args.steps:
        if sid in fetched:
            summarise(sid, *fetched[sid])

    if args.diff:
        if len(args.steps) != 2:
            ap.error("--diff needs exactly two step ids")
        a, b = args.steps
        if a in fetched and b in fetched:
            diff_steps(fetched[a], fetched[b])

    if args.export:
        target = args.steps[0]
        wf = fetched[target][2]
        path = Path(args.export)
        path.parent.mkdir(parents=True, exist_ok=True)
        # sorted keys + indent: the point of exporting is that the graph becomes
        # REVIEWABLE IN GIT. A stable ordering keeps a one-field change to a
        # one-line diff, which is what makes silent drift detectable.
        path.write_text(json.dumps(wf, indent=2, sort_keys=True) + "\n")
        print(f"\nwrote {path}")


if __name__ == "__main__":
    main()
