# Auditing turbo-carnival ComfyUI pipelines (which base model is live)

Session 2026-08-25: user asked "use Cyberrealisticponyv85 as base model." The
harness was ALREADY on it (`turbo-one-step-clean`). The audit path below is the
reusable part — it answers "what base/loaders does the harness actually render
with" without asking ComfyUI, and caught a real drift in the editor file.

## 1. Check the harness constant first (no DB needed)

`Growth::ContentGenerator` resolves its pipeline at runtime:

```ruby
PIPELINE_NAME = 'turbo-one-step-clean'   # preferred
FALLBACK_PIPELINE_NAME = 'turbo-one-step' # old NSFW base, fallback only
# resolve_pipeline: Pipeline.find_by(name: PIPELINE_NAME) || find_by(name: FALLBACK)
```

If the constant already points at the pipeline you'd build, the harness side is
done — verify the graph, don't rebuild.

## 2. Dump loaders per pipeline from the DB

Workflows live in `pipeline_steps.comfy_workflow_json` — stored in ComfyUI
**API format**: a Hash keyed by node id → `{"inputs": {...}, "class_type": "...",
"_meta": {"title": ...}}`. NOT the editor format (`nodes[]` array with
`widgets_values`). The `~/Downloads/*.tokenized.json` export is also
node-id-keyed.

```ruby
require "json"
Pipeline.where(id: [20, 21]).order(:id).each do |p|
  puts "===== [#{p.id}] #{p.name} ====="
  p.pipeline_steps.each do |s|
    JSON.parse(s.comfy_workflow_json).each do |nid, node|
      ct = node["class_type"].to_s
      next unless ct =~ /Loader/i || ct =~ /Save|Filename/i
      sel = node["inputs"].select { |k, _| k =~ /name|ckpt|unet|vae|clip|filename|prefix|seed/i }
      puts "  node #{nid} #{ct} -> #{sel.inspect}"
    end
  end
end
```

Run via `bundle exec rails runner` (remember `rvm use 3.4.5`).

## 3. Trace the ACTUAL sampler chain (don't trust node titles)

The graph contains dead branches. Follow input references `["<nodeid>",
<output_index>]` backward from the KSampler(s), or forward from a loader:

```ruby
# find every consumer of a node's outputs
j.each { |nid, node| node["inputs"].each { |k, v|
  puts "  #{nid}.#{k} = #{v.inspect}" if v.is_a?(Array) && v[0] == "87" } }
```

Verified sampled path in `turbo-one-step-clean` (step 40):

```
87 CheckpointLoaderSimple (pony/cyberrealisticponyV85.TgCf.safetensors)
  -> 48 CLIPSetLastLayer (stop_at_clip_layer -2) -> feeds 97 LoRA stack clip
  -> 97 Power Lora Loader -> 70 TorchCompileModel -> 96 KSampler (euler,
     steps 125, cfg 5.5, denoise 1, EmptyLatentImage 816x1024)
96 KSampler conditioning text = node 88 (NOT node 50; node 50 = {{prompt}} path)
21 SaveImage filename_prefix = {{run_name}}
37/55 {{auto_seed}}
```

## 3b. Trace LINKS, never the node list (canvas format)

Canvas links live in `workflow.links[]` as
`[link_id, origin_node, origin_slot, target_node, target_slot, type]`. Build both directions once —
`(node, slot) -> consumers` and `(node, slot) -> source` — then walk them. This is the only reliable way
to answer "what actually reaches this sampler" and "is this node wired to anything at all".

**The failure shape to hunt for: a feature built and left one connection short.** Two independent graphs
in this project each contained one, and neither is visible from the node list:

- a complete bypass — `GetMaskSizeAndCount` → `Int To Number` → *nowhere*, a `Constant Number` = 0
dangling, and both `LazySwitchKJ.switch` inputs hardcoded `False`;
- a pose extractor whose output feeds **only a `PreviewImage`**, while the ControlNet consumes a
hand-picked image file instead.

Both *look* present on the canvas and do nothing. So a node existing proves nothing: **check that its
output has a consumer inside the sampled path**, and that any `switch`/boolean input is driven by a node
rather than by a literal.

When you have two graphs of the same architecture, diff them by class + named parameters rather than by
node id — ids differ, and the diff is what tells you which stage actually differs.

## 4. Dead FLUX branch (VRAM waste — the OOM suspect)

Nodes 43 (UNETLoader `flux1/flux1-dev.sft`), 81 (DualCLIPLoader t5xxl+clipL),
90 (VAELoader `ae.safetensors`), 41 (FLUX LoRA stack) are loaded into VRAM
every run but consumed ONLY by each other — nothing in the sampled path reads
them (41.model=[43,0], 41.clip=[81,0] are its own inputs). On the memory-tight
4090 (~23/24GB, known OOM-on-cold-load) this is roughly half the budget burned
on models the sampler never uses. Stripping it is the leading candidate for
making renders single-shot; node 71 (SDXL VAE) is also on the Flux side.

## 5. Editor workflow file vs DB drift (REAL pitfall)

The DB step JSON is the source of truth for the harness. But manual ComfyUI
runs load the editor file
`/mnt/fscache/essdee/ComfyUI/user/default/workflows/turbo-one-step.json` —
an editor-format `nodes[]` array where a loader's checkpoint is
`node['widgets_values'][0]`. These two CAN and DO drift (2026-08-25: DB clean
on cyberrealisticpony, editor file still `pony/Pornmaster_v2551619.safetensors`).
Changing a base model = edit BOTH: DB step JSON (`ckpt_name`) + editor file
(`widgets_values[0]`). Different schemas — don't copy one into the other.

**Read widget values by NAME, never by position.** The canvas file carries its own parameter names: an
entry of `node.inputs[]` that has a `widget` key is a *named* widget, and `widgets_values` lines up with
exactly those entries (link-only inputs have no `widget` key and are excluded). So build
`{inputs[i].name: widgets_values[i]}` over `i where inputs[i].widget is not None` and pair the two files
**by name**. Never index, and never assume a class's declared input order — the canvas format names its
widgets the same way the API format names its `inputs`, so one dict comparison reads both schemas.

Repo tooling that already does this: `scripts/dump_canvas_workflow.py` (histogram + named widgets),
`scripts/compare_hand_paths.py` (API vs canvas, parameter by parameter), `scripts/trace_lily_pose.py`
(link walk).

## 6. Live ComfyUI endpoint cheatsheet

ComfyUI runs from `/mnt/fscache/essdee/ComfyUI` as
`python main.py --listen 0.0.0.0 --enable-manager --fp32-text-enc`, API on
`http://localhost:8188` (`Rails.application.config.comfyui.base_url`):

- `GET /system_stats` — up? version, ram
- `GET /object_info/CheckpointLoaderSimple` — list available checkpoints
  (parse `.input.required.ckpt_name[0]`; also VAE/UNET/LORA equivalents)
- `GET /queue` — `queue_running` + `queue_pending` (prompt ids)
- `GET /history/<prompt_id>` — job status (what PollJobStatus uses)
- `POST /prompt` — submit API-format workflow

Checkpoint list lives on the GPU box, not in the repo — always verify a
`ckpt_name` exists there before pointing a pipeline at it.

**But do NOT conclude a model is missing from the local `models/` tree.** ComfyUI resolves through every
root declared in `extra_model_paths.yaml` — here `local_hot` → `/mnt/models/`, `nas` →
`/mnt/nas-ai-models/`, `comfyui_local` → the ComfyUI tree — so a `comfyui_local` directory can be empty
while the model is perfectly available from `nas`. Read the declared roots and `ls` the exact path, or ask
`/object_info/<Loader>` for the enumerated list.

A recursive `find` across the NAS mounts can **time out and return a false negative**: measured, a `find`
that reported nothing was simply wrong — the 2.5 GB model was at its declared path. Never tell the founder
an asset is missing, or that a saved workflow is unrunnable, on the strength of a `find`.

## Open observation (uninvestigated, 2026-08-25)

`ComfyuiJob` rows (7290–7294) stayed `submitted` for hours while fresh PNGs
existed in `/mnt/fscache/essdee/ComfyUI/output/` and the queue drained — the
poller looked stalled. Not diagnosed; if it recurs, compare `ComfyuiJob`
status vs live `/queue` and `/history` before assuming ComfyUI is broken.