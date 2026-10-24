# ComfyUI workflow plumbing (turbo-carnival)

How a render workflow is stored, parameterised, and submitted — and the traps that
make a wrong render look like a successful one.

## The file is the source of truth, the DB is a load target

A workflow is executed from `pipeline_steps.comfy_workflow_json` (a text column),
never from the filesystem. Storing it **only** there is the failure mode: the column
has no git history, so an edit to it is unfalsifiable — an identity/quality block was
silently rewritten on one copy, that copy was wired into production, and no review
could have caught the change.

- Versioned home: `comfy_workflows/<slug>/stepN_<name>.json` (ComfyUI **API** format:
  `{node => {class_type, inputs, _meta}}`).
- Load it with `rake "pipeline:register[<dir>,<pipeline-name>]"` — idempotent, replaces
  each step FROM the file, never touches another pipeline. The task rejects a UI-format
  export, because that would sit happily in the column and only fail at submit time.
- Pull an existing DB step out to a file with the inspector's `--export` before editing
  it, so the change arrives as a reviewable diff.

## The placeholder chain: three passes, three classes

Order matters — each pass sees a different representation.

1. **`BuildJobPayload#replace_template_variables`** — plain `gsub` on the JSON *string*,
   before `JSON.parse`. Map = `pipeline_run.variables` + `prompt` (run column) +
   `run_name` (run name) + `timestamp` / `timestamp_ms` / `random` +
   `parent_image_path`. Values escaped via `to_json[1..-2]`.
2. **`PipelinePromptSafety.sanitize_workflow`** — rewrites stored text; the single
   choke point every render passes through. Logs each rewrite.
3. **`SubmitJob#apply_job_variables`** — re-serialises and resolves the two runtime
   tokens: `"{{job_id}}"` and `"{{auto_seed}}"` (= run seed or `1000000`, plus `job.id`).
4. **`ComfyuiClient#submit_workflow`** — `POST {base_url}/prompt` with
   `{prompt: <workflow>}`; the returned `prompt_id` is normalised to `job_id`.
   `base_url` = `COMFYUI_BASE_URL`, default `http://localhost:8188`.

Output folder = `File.join(pipeline_run.target_folder, step_name.parameterize)`.

### Token traps (each one produces a plausible-looking wrong render)

- **`{{job_id}}` and `{{auto_seed}}` match ONLY the quoted form** (`'"{{auto_seed}}"'`).
  They must be a whole JSON string value; embedded inside a longer string they are
  never substituted and nothing errors.
- **An unsubstituted token fails silently.** ComfyUI receives the literal text
  `{{prompt}}` as the prompt. A step with `needs_run_prompt = false` and a run carrying
  no variables is exactly this trap.
- **Tokenizing two fields to the same name collapses them.** Two nodes that held
  *different* hardcoded seeds both became `{{auto_seed}}` and now resolve to one value.
  Before tokenizing, check whether the fields were independent on purpose.
- **rgthree `Power Lora Loader` stores LoRAs in an ARRAY of objects**
  (`loras: [{on, lora, strength}]`), not as scalar input keys — a plain `{{token}}`
  cannot reach an individual strength. Parameterising LoRA weights needs a dedicated
  transform; it is not a one-line edit.

## Inspecting a workflow: `bin/tc_workflow.py`

Read-only. Run it BEFORE editing any graph — a workflow is ~75 nodes and only about
five of them matter.

```bash
python3 bin/tc_workflow.py --inventory            # every stored step + its placeholders
python3 bin/tc_workflow.py 39                     # models, LoRAs, sampler, resolution, text
python3 bin/tc_workflow.py 39 40 --diff           # node-by-node difference
python3 bin/tc_workflow.py 39 --set 87.ckpt_name={{checkpoint}} --export out.json
```

`--set` edits the first step's graph in place before summarising and exporting, which
is how a parameterised variant is derived from a stored step. `--export` sorts keys so
a one-field change is a one-line git diff.

## The turbo-one-step graph (75 nodes — these are the ones that matter)

| Node | Role |
|---|---|
| 87 | `CheckpointLoaderSimple` — the Pony-side base checkpoint |
| 43 | `UNETLoader` — `flux1/flux1-dev.sft` (Flux side) |
| 81 | `DualCLIPLoader` — t5xxl + a custom clipL |
| 71 / 90 | `VAELoader` — SDXL vae (pony side) / `ae.safetensors` (flux side) |
| 41 / 97 | `Power Lora Loader (rgthree)` — flux LoRA stack / pony LoRA stack |
| 96 | `KSampler` — base pass (dpmpp_2m_sde_gpu, karras, 125 steps, cfg 5.5, denoise 1) |
| 110:108/109 | euler/beta, 35 steps, denoise 0.66 — **face inpaint pass** |
| 112/113 | euler/beta, 25 steps, denoise 0.6 — **hands inpaint pass** |
| 16 / 24 | `ApplyCLIPSeg+` masks (`head`, `hand`) that drive those two inpaint passes |
| 114 | `EmptyLatentImage` — 816×1024, batch 1 |
| 50, 111 | `Text Multiline`, both `{{prompt}}` — one token drives two nodes |
| 88 | `Text Multiline` — identity / quality / wardrobe block |
| 79 | `CLIPTextEncode` — negative prompt |
| 21 | `SaveImage` — `filename_prefix` = `{{run_name}}` |

"Flux inpaints the face and hands" is implemented as **CLIPSeg masks feeding two extra
low-denoise euler passes** — not a separate model. It is a Pony + Flux hybrid: two
checkpoints, two VAEs and two CLIP paths in one graph.

## A `-clean` sibling can be the live pipeline

`turbo-one-step` (step 39) and `turbo-one-step-clean` (step 40) are the same 75-node
graph with **exactly one node differing — node 88**, the identity/quality block. The
`-clean` copy had body/wardrobe/mood language replaced with
"wholesome / fully clothed / modest / natural beauty".

**Check which pipeline the calling code names before concluding what is being
rendered.** A sanitized twin can be the production path (`ContentGenerator`'s
`PIPELINE_NAME` pointed at the `-clean` variant while the un-sanitized original sat
unused beside it), which makes every downstream quality judgement wrong.

Also separate the two layers: call
`PipelinePromptSafety.sanitize_workflow(JSON.parse(step.comfy_workflow_json))` and read
the returned change list. A **runtime** rewrite and a **stored** edit are different
things, and a workflow can be hit by both.

## Checkpoint as a bounded run parameter

`PipelineCheckpointAllowlist` (`packs/job_orchestration/app/services/`) holds the
founder-approved base set and mirrors the checkpoint directory.

- Resolve it at the choke point (`BuildJobPayload`), and **only when the workflow text
  contains the `{{checkpoint}}` token**, so unrelated pipelines are unaffected.
- blank value → the known-good baseline, so an unpinned run reproduces known-good output
  and can never ship the literal token as a filename.
- named-but-unapproved → refuse, before a multi-minute model load.
- This is **scope control, not a quality gate**. Quality is measured and ranked by
  controls (elo, identity similarity, engagement) and never vetoed here. Fail-closed
  belongs on the legal floor and on an out-of-scope input, not on taste.
- An unapproved-but-real filename would otherwise surface as a cryptic ComfyUI "file not
  found" *after* the load.

## GLCommand does not propagate the exception class

`GLCommand::Callable` reports failure by returning a context with `success? == false`
and the message in `.error`. A `rescue MySpecificError` around a command call **never
fires**. Callers and verification scripts must branch on `res.success?` and read
`res.error`.

## Running rake and rails runner here

Run `bundle exec rake ...` and `bundle exec rails runner <file>` directly — the default
ruby is already the pinned 3.4.5 (RVM is system-wide at `/usr/share/rvm`, not `~/.rvm`),
so there is no activation step to perform first.

Keep throwaway verification scripts in the profile scratch directory, not in the repo,
and pass them to `rails runner` by absolute path.
