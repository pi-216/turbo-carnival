# ComfyUI render workflows — storage, placeholders, and batch rendering

Depth for the render side of turbo-carnival: where a workflow actually lives, how
placeholders reach it, how to change one safely, and how to render a comparison batch.

## A workflow is DATA in Postgres, not a file in the repo

`pipeline_steps.comfy_workflow_json` (text) holds the ComfyUI **API-format** graph
(`{node_id: {class_type, inputs, _meta}}`). `pipelines` groups steps; `pipeline_steps.order`
is unique per pipeline.

Inspect before changing anything — never read the JSON by hand:

```bash
# token inventory across every stored step
psql -d turbo_carnival_development -At -c "select pipeline_id||'/'||id||' '||name||' -> '||coalesce((select string_agg(distinct m[1],',') from regexp_matches(comfy_workflow_json,'\{\{([A-Za-z0-9_]+)\}\}','g') m),'(none)') from pipeline_steps order by pipeline_id,\"order\";"

python3 bin/tc_workflow.py --inventory      # the same, formatted
python3 bin/tc_workflow.py 39 40 --diff     # what differs between two steps
```

`bin/tc_workflow.py` is read-only and also lists every model / LoRA / VAE / CLIP file a
graph loads, its sampler settings and its resolution.

## The placeholder chain — three passes in three different classes

`{{token}}` substitution is split up, and the split is a trap:

1. `BuildJobPayload#replace_template_variables` — string level, BEFORE the JSON is parsed.
   Map = `pipeline_run.variables` + `prompt` (run column) + `run_name` (run `name`) +
   `timestamp` / `timestamp_ms` / `random` + `parent_image_path`.
2. `PipelinePromptSafety.sanitize_workflow` — rewrites stored text on every submit.
3. `SubmitJob#apply_job_variables` — on the re-serialised graph: `"{{job_id}}"` and
   `"{{auto_seed}}"`, where `auto_seed = pipeline_run.variables["seed"] || 1000000 + job_id`.

Gotchas, each of which costs a silent bad render:

- **Pass 3 matches the QUOTED form only** (`gsub('"{{job_id}}"', …)`). A token embedded in a
  longer string never substitutes. Pass 1 has no such restriction.
- **An unsubstituted token is not an error.** ComfyUI receives the literal text `{{prompt}}` as
  the prompt and nothing logs it. Assert that zero `{{` remain in the payload before submitting.
- **A step with `needs_run_prompt=false` but `needs_run_variables=true` takes its prompt from
  the run's variables**, not the prompt column — a run carrying neither yields the literal.
- **One `{{prompt}}` can drive several nodes**; the one-step graph feeds two Text Multiline
  nodes, so editing that text changes both.
- **Tokenising two different hardcoded seeds to the same `{{auto_seed}}` collapses them into
  one value.** If the graph relied on two independent seeds, that behaviour is gone without a
  diff to show it.

## Drift: why the FILE is the source of truth, not the column

A workflow that exists only as a DB text column cannot be diffed, reviewed or reverted. A
copy of the production graph had its identity/quality prompt block rewritten — body and
wardrobe language replaced with language about being fully clothed and modest — and that copy
was wired in as the production pipeline. No review could see it; the visible symptom was
content quality, not an error.

Convention that prevents it:

- The workflow lives in git at `comfy_workflows/<pipeline-slug>/stepN_<name>.json`.
- Load it with `rake "pipeline:register[<dir>,<pipeline-name>]"` — idempotent, scoped to one
  pipeline, and the file wins on re-run. It **rejects a UI export**: a UI graph sits happily in
  the text column and is then refused by ComfyUI at submit time, after the model load.
- Build a variant by exporting from a known-good step and editing tokens, not by hand-editing
  the column:
  `python3 bin/tc_workflow.py <step_id> --set 87.ckpt_name={{checkpoint}} --export <path>`.
  `--set` handles scalar inputs only; values inside an input **array** (e.g. an rgthree
  Power Lora Loader's `loras: [{lora, strength, on}, …]`) are not addressable that way.
- **Diff a variant against its parent before shipping it.** Two of these pipelines differ in
  exactly one node; without the diff the change is invisible.

## Parameterising a base model — the checkpoint allowlist

`{{checkpoint}}` feeds `CheckpointLoaderSimple.ckpt_name`. `PipelineCheckpointAllowlist`
resolves it at the `BuildJobPayload` choke point: blank → the known-good baseline, a named
value → must be in `ALLOWED`, anything else raises.

- The list mirrors the checkpoint directory on the model host: it states the approved set, it
  is not a quality judgement. Quality is ranked by controls and never vetoed here.
- An unapproved value would otherwise surface as a cryptic "file not found" AFTER a
  multi-minute model load, so failing at payload build is strictly cheaper.
- Blank defaulting to the known-good baseline keeps an unparameterised run behaviourally
  identical to the old production path.

## Rendering a comparison batch

`bin/tc_render.py` renders candidates for a **ranking pool** — a different job from
`Growth::ContentGenerator`, which renders and schedules posts. It POSTs directly to ComfyUI
on `:8188`, with no Rails boot per render:

```bash
python3 bin/tc_render.py status
python3 bin/tc_render.py checkpoints      # validate the approved set against /object_info
python3 bin/tc_render.py sweep --scene <slug> --prompt-file scenes/<slug>.txt \
    --out <pool-dir> --checkpoints all [--seed N] [--retries 2]
```

- **Type-aware substitution.** A leaf that IS exactly a token takes the token's native type, so
  `{{auto_seed}}` lands as a JSON number. The Rails path can only emit string literals, which
  is why its `{{auto_seed}}` must appear as a bare quoted string.
- `/prompt` returns a `prompt_id`; poll `/history/{prompt_id}` until it appears, then fetch the
  bytes from `/view?filename=…&subfolder=…&type=output`. A `/history` entry with
  `status_str == "success"` but no image output means the SaveImage node never ran.
- **Validate every checkpoint against `/object_info/CheckpointLoaderSimple` first.** A pool
  member with an unusable VAE passes a naive existence check and then fails at DECODE.
- **One shared seed across every item in a sweep**, rotated per sweep. Seed is a held-fixed
  attribute like any other: varying it ranks seed luck, not the thing under test.
- **A single OOM that succeeds on retry is known behaviour** at this card's ~23 GB peak of
  24 GB. Retry once or twice; treat repeated failure as real. Expect roughly 5–10 minutes per
  render, with a slow first render — the cold `torch.compile` warm-up is CPU-heavy and shows
  low GPU utilisation, which looks like a stall but is not one.
- Write `manifest.json` into the pool directory (file → checkpoint → scene → seed → sha256 →
  workflow hash). An elo-picker `Project` stores only paths and bytes; without the manifest
  the pool-to-provenance mapping is lost.
- Pool shape follows the `elo-picker-development` rules: one pool per held-fixed group with a
  single varying axis. A checkpoint sweep at one scene is one pool; replicate across scenes
  for robustness rather than merging scenes into one pool.

## Do not fail closed on a running, unclaimed ComfyUI

A fail-closed preflight that refuses to queue against a ComfyUI it did not start will silently
starve renders: the instance is up, idle and usable, the render never submits, and the queue
stays empty with no error raised anywhere. Check `/queue` and free VRAM and queue behind the
operator's job instead — ComfyUI serialises execution and evicts models as needed. Keep the
claim protocol for launching your OWN instance.

## Agent edits to this data are not policy

A stored workflow, prompt block or constraint that an agent rewrote to match its own
preference is not a project rule. Concretely: a prohibition written by a previous agent into
`THESIS.md` was being enforced as though it carried founder authority, and the same
preference had been written into the production workflow's prompt block. Both had to be
withdrawn by the founder.

- An agent may not promote its own safety or taste preference into a founder red line. A red
  line is founder-authored or founder-ratified, or it does not bind.
- Data edits that encode policy belong in git where they can be diffed, and they need founder
  sign-off — not a silent `UPDATE`.

## Prerequisites

Confirm the interpreter before invoking a version manager: run `ruby -v` and only switch
versions if it does not already report the pin. A `rvm use …` step aimed at a shell profile
that is not present fails with empty output and a non-zero exit, which reads as a mysterious
command failure rather than a version problem.
