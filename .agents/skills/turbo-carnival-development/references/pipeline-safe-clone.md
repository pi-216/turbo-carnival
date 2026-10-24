# Cloning a ComfyUI pipeline into a SAFE variant (reversible experiment)

Session 2026-08-24: NSFW gate rejected 14/14 hourly renders 0.87–0.9999.
Initial assumption (wrong): prompt/pillar drift was the cause. Real cause was at
the NODE level — the stored graph itself (not the run prompt) was NSFW-tuned.

## Diagnostic: gate rejects EVERYTHING → inspect the stored graph, not the prompt

When the NSFW gate (or any content gate) rejects everything regardless of scene
or pillar, the driver is in the stored pipeline, not the generated prompt.

1. Pull the pipeline step's stored workflow:
   ```ruby
   step = Pipeline.find_by(name: 'turbo-one-step').pipeline_steps.order(:order).first
   j = JSON.parse(step.comfy_workflow_json)
   wf = j['workflow'] || j
   ```
2. Inspect the three content drivers (all live in the workflow JSON):
   - **Base checkpoint** (CheckpointLoaderSimple node): if it's an NSFW family
     (Pornmaster, anything *-pornmaster), that's the dominant driver.
   - **LoRA stack** (Power Lora Loader / rgthree): read each `lora_N` slot —
     `on:` + `lora:` path. NSFW body-tune / identity ties live here.
   - **Conditioning text** (Text Multiline feeding the KSampler / CLIPTextEncode):
     the actual sampler prompt is NOT always node 50. In turbo-one-step the
     KSampler (96) reads node 88's text, which contained underboob/obedient/
     submissive — node 50 was a different, less-influential path.
3. Copy the submitted payload from the `comfyui_jobs.job_payload` JSONB column
   or `log/development.log` INSERT to confirm exactly what ran.

## Verified node map (turbo-one-step, 2026-08-24)

| node | role |
|---|---|
| 87 | CheckpointLoaderSimple — base (was NSFW Pornmaster) |
| 97 | Power Lora Loader — lora_2 identity ON, lora_3 sk1nny NSFW body ON, lora_1 underboob/microskirt/micro-bikini OFF |
| 88 | Text Multiline — the KSampler(96) conditioning text (NSFW terms live here), NOT a quality/negative-only node |
| 50 | Text Multiline = `{{prompt}}` (the pillar/scene prompt you control) |
| 96 | KSampler (125 steps) on node 60/88 conditioning |
| 37/55 | `{{auto_seed}}` tokens |
| 21 | SaveImage `filename_prefix = {{run_name}}` |

## Safe-clone recipe (idempotent, original untouched)

See `tmp/build_clean_pipeline.rb` from the project for a working, idempotent
builder. Approach:

1. Parse the source step's workflow JSON fresh from the DB (do NOT assume node
   structures — print class_type + inputs first, they drift).
2. Mutate only the content drivers:
   - node 87 `ckpt_name` -> `pony/cyberrealisticponyV85.TgCf.safetensors`
     (same pony family keeps identity LoRAs, drops NSFW fine-tune). Verify the
     target safetensors exists under `/mnt/nas-ai-models/checkpoints/pony|loras/`
     first.
   - node 97: force the pork NSFW LoRAs OFF, keep identity + neutral
     lighting/skin/detail LoRAs ON.
   - node 88: rewrite text, strip underboob/obedient/submissive/body terms,
     keep identity tags (sarah1a3, freckles), add fully-clothed/modest wording.
3. Register as NEW Pipeline `turbo-one-step-clean` + step, store
   `JSON.dump(j)` (load via `JSON.parse`). Never overwrite the original.
4. Verify by re-reading the clone from DB (dig node87/88/97 + token presence),
   then fire ONE real render and check the gate score.

## Single-axis variants: enforce the axis mechanically, and TYPE the values

Two failure classes bite whenever you build a variant to test ONE change.

**1. The edit silently touches more than one thing.** However you build it, re-read BOTH files after the
write, flatten every leaf path, and **refuse** (delete the variant, exit non-zero) unless exactly the
intended leaves changed. "One axis per test" is otherwise a promise; this makes it a fact. Use
`scripts/make_variant.py`:

```
/usr/bin/python3 scripts/make_variant.py \
  --base comfy_workflows/<x>/step1_generate.json \
  --out  comfy_workflows/<x>_<axis>/step1_generate.json \
  --expect 96.inputs.cfg=5.5 --set 96.inputs.cfg=7
```

`--expect` asserts the baseline still holds **before** the edit (a moved baseline is caught, not inherited);
the post-edit leaf diff must equal the number of `--set` ops.

**2. The value is written with the wrong TYPE.** A CLI `--set …=7` arrives as the *string* `"7"`; written
into a field the node declares as FLOAT it becomes `"7"`, which ComfyUI may coerce silently or reject —
and either way the variant no longer matches the axis it claims. Coerce numeric/boolean strings to real
JSON values, and **refuse any write that changes the value's type** (num→str, bool→num) as a side effect.
This project has already lost time to this exact class in the substitution chain, where a string literal
where a number belonged reached the model with no error.

**Serve the arms as two immutable FILES, never as a mid-sweep edit.** `bin/tc_render.py sweep --workflow
<path>` re-reads the file per render, so editing one in place between arms silently makes the batch mixed.
Two files also let each arm carry its own sha256 into the blinding key.

**When the change is structural, assert the untouched SCOPE instead.** Adding a ControlNet or re-wiring
conditioning is not a single leaf, so the leaf-diff guard cannot apply. The equivalent evidence is a
**scope assertion**: prove that every node on the paths you did *not* mean to touch is byte-identical
between the arms, and that all additions sit inside the intended path. State the scope explicitly — an
unstated scope is indistinguishable from a sloppy diff.

Repo tooling: `scripts/make_variant.py` (typed single-axis variant + leaf-diff enforcement),
`scripts/replicate_pairs.py` (generalised two-arm paired harness: per-arm frozen-config assertions,
one-axis check, post-render axis-bite check, blinded sheets, key).

## Wiring / verification

- ContentGenerator resolves `PIPELINE_NAME` ('turbo-one-step-clean') and falls
  back to `FALLBACK_PIPELINE_NAME` ('turbo-one-step') via `resolve_pipeline`.
- End-to-end (2026-08-24): clean render scored nsfw 0.0036 (normal) vs 0.9999
  on the Pornmaster graph; post imported + captioned + scheduled. Media URL
  returned 200 through the carnival tunnel.
- Fallback caption pitfall: runs where caption generation fails get the
  hardcoded `"Fresh look ✨"` placeholder — a late-step that silently degrades
  queue quality. Regenerate: `PostAutomation::GenerateCaption.call(photo:,
  persona:, pillar:)` then `post.update!(caption:)`.
- Duplicate scheduling slot: `Post#scheduled_at` gets `offset_days.days` from
  now each generation, so multiple generated posts can collide on one slot.
  Nudge apart: `p.update!(scheduled_at: p.scheduled_at + 1.day, ...)`.

## Pitfall: Rails autoload requires snake_case filename matching the constant

`Growth::PillarPrompt` in file `pill_scene.rb`/`pillarprompt.rb` would NOT
autoload (NameError: uninitialized constant). The file must be
`pillar_prompt.rb` to resolve `Growth::PillarPrompt`. When adding a new
service/constant, name the file to match the constant's snake_case.