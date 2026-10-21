# Validated baseline -- turbo-one-step-v2

> **Status:** CURRENT — the validated baseline render configuration

**Status: FOUNDER-ACCEPTED.** On 2026-10-18 the founder reviewed four renders spanning all four
working checkpoints and said *"all four are acceptable"*, and confirmed the checkpoint that had
twice produced two people now *"shows only one person"*.

This file is generated from the live workflow so it cannot carry a stale value. Regenerate
rather than hand-edit.

## Provenance

```
workflow : comfy_workflows/turbo_one_step_v2/step1_generate.json
sha256   : 1f8791c7275240acb3596c6347da0b8013332dcef448461734ce38be39295146
scene    : scenes/bedroom-front.txt   (1051 chars, front/side facing)
```

Reproduce a set:

```bash
/usr/bin/python3 bin/tc_render.py sweep --scene bedroom-front \
  --prompt-file scenes/bedroom-front.txt --out <POOL_DIR> \
  --checkpoints CRPv18_PM25.safetensors,CRPv18_PM40.safetensors,Pornmaster_v2551619.safetensors,cyberrealisticponyV85.TgCf.safetensors \
  --seed <SEED> --retries 2
```

## Samplers (the strengths that matter)

| stage | node | value |
|---|---|---|
| base render (pony) | 96 `KSampler` | steps 125, denoise 1, scheduler `karras`, cfg 5.5 |
| **face inpaint (flux)** | 110:109 | steps 35, denoise **0.66** |
| **hand inpaint (flux)** | 113 | steps 25, denoise **0.68** |

Hand denoise was raised to 0.68 at the founder's direction. Caveat carried forward: the pass is
node 86 *"Young female arm and hand"*, i.e. it re-renders the ARM too, and a higher denoise
re-renders more of an arm that may already have been correct. Arm artefacts appeared in 0.68
renders; a 0.62-vs-0.68 same-seed comparison is the way to settle whether the arm is collateral.

## Positive -- identity block (node 88)

```
score_9, score_8_up, score_7_up, 1girl, solo.

Add more details 
adult woman in her late twenties, petite face, small nose, s1_dram, sk1nny, sarah1a3

Admiring, affectionate, obedient, submissive.

sarah1a3, slender, freckles, long flowing brunette hair down to her waist, tiny waist

Detailed, skinny model, full round breasts, pretty, cute, kawaii, adorable
```

`1girl, solo` is the half of the multi-person fix that was missing. Without it, the negative
guards alone did NOT prevent two subjects (cyberrealisticponyV85 produced two people twice).

## Negative (node 79)

```
score_5, score_4, worst quality, low quality, normal quality, lowres, bad anatomy, bad hands, extra limbs, poorly drawn face, poorly drawn hands, mutation, deformed, blurry, bad anatomy, disfigured, poorly drawn, bad picture, out of frame, duplicate, morbid, mutilated, extra fingers, mutated hands, poorly drawn hands, poorly drawn face, mutation, deformed, blurry, dehydrated, bad anatomy, bad proportions, extra limbs, cloned face, disfigured, gross proportions, malformed limbs, missing arms, missing legs, extra arms, extra legs, fused fingers, too many fingers, long neck, sunken_eyes, 2girls, multiple girls, two women, {{negative_prompt}}
```

`2girls, multiple girls, two women` stay global (class-1 correctness: one subject, one hand).
`nipples, areola` moved into the **scene spec** (PRD 0007 B2, #109): the node ends in the
`{{negative_prompt}}` token, which the renderer resolves from the scene's own declaration — the
scene files under `scenes/` declare `Negative: nipples, areola` (consumed by `tc_render.py`,
kept out of the image prompt), and the production rail resolves it from the wardrobe rung in
effect (`Growth::ContentGenerator` records it on the run row, next to `wardrobe_level`). A
scene that covers in text carries the terms; a scene that exposes the areola in text is free of
the suppression — the default is freedom, and a covering scene must say so.
Deliberately NOT added: `naked` / `nude` / `topless` -- those would suppress the bare shoulders
and legs the look depends on, and rear exposure is a POSE problem, not a coverage one.

## Scene

```
Scene: A woman alone in a sunlit bedroom in the late morning, soft daylight through sheer
curtains falling across the bed and the floorboards. Composition: vertical three-quarter
front view, the camera positioned fully in front of her — she faces the lens and is never
turned away, shoulders angled a little toward the lens, shallow depth of field (f/2.0) with
the room softly blurred behind her. Pose: seated on the edge of the bed, leaning forward
slightly with her forearms resting on her thighs, both hands visible and relaxed with fingers
together and clearly separated from each other, head level and looking into the lens with an
easy, warm smile. Wardrobe: wearing only a short cream linen apron, the bib covering her chest
completely, tied at the waist with the apron hanging flat over the front of her torso; bare
shoulders and arms, bare legs, no other clothing. Mood: relaxed, intimate, unhurried morning at
home. Photography Style: 50mm lens, natural window light, candid documentary feel,
photorealistic, fine skin and fabric detail, 8k.
```

Front/three-quarter-front facing with an explicit *"never turned away"* instruction.

## LoRAs

Pony side (node 97) -- drives the base image:

| lora | on/off | strength |
|---|---|---|
| `pony/underboob.safetensors` | off | 0.75 |
| `pony/sarah1a3_pony_pornmaster_v1.safetensors` | **on** | 0.8 |
| `pony/sk1nny_pony_pornmaster_v1-000002.safetensors` | **on** | 0.8 |
| `pony/dramatic-lighting.safetensors` | **on** | 0.6 |
| `pony/reqlistic-skin-slider.safetensors` | **on** | 0.65 |
| `pony/add-more-details.safetensors` | **on** | 0.65 |
| `pony/microskirt.safetensors` | off | 0.25 |
| `pony/micro-bikini.safetensors` | off | 1 |

Flux side (node 41) -- drives the face and hand inpaints:

| lora | on/off | strength |
|---|---|---|
| `flux/sarah1a3.safetensors` | **on** | 1 |
| `flux/flux_realism_lora.safetensors` | **on** | 1 |
| `flux/tg.safetensors` | off | 0.6 |

## Checkpoints

Working (4): `CRPv18_PM25`, `CRPv18_PM40`, `Pornmaster_v2551619`, `cyberrealisticponyV85.TgCf`.

Failing (1): `cyberrealisticPony_v180Coreshift` -- dies at **node 96 (the base pony render)** with
a Dynamo fake-tensor error, deterministically across attempts. Believed to be the
`--disable-comfy-compiler` path; untested because the flag is not in the current launch line.

## Known failure classes and their sites

| site | failure | behaviour |
|---|---|---|
| node 96 | cyber v180Coreshift, Dynamo fake-tensor / SDPA dtype | deterministic, checkpoint-specific |
| node 84 | OOM on the flux face pass (21.17 GiB allocated, 142 MiB free) | transient, absorbed by `--retries` |
| node 64 | `Bounded Image Crop with Mask` -- empty CLIPSeg **`hand`** mask (node 64's mask comes from 29 ← 24, and node 24 is `prompt: hand`) | deterministic per COMPOSITION, not per checkpoint: same checkpoint at a different seed renders fine |

Node 64 mitigation if it recurs often: the `hand` CLIPSeg threshold (node 24) is currently 0.4.
Lowering it makes an empty mask less likely and turns a hard crash into a render. But the hand mask
can legitimately come back empty when no hand is visible in frame, so the durable fix is a non-empty
guard on the crop step, not only a lower threshold. Source: `torch.where(rows)[0][[0, -1]]` has no
empty guard (`was-ns/WAS_Node_Suite.py:12456`).

## Resolved defect attributions

Each of these looked like "the model is bad" and turned out to be something specific:

| symptom | actual cause | fix |
|---|---|---|
| naked behind | wardrobe x pose interaction: front-only apron wording + bare back + from-behind camera. NOT a checkpoint effect. | front/side facing; from-behind is fine WITH clothing |
| two women | the positive half of the multi-person fix was missing (`1girl, solo`) | added; verified -- cyber V85 now renders one person |
| kitchen rendered inside a bedroom | **my own design notes** were appended to the scene file and sent as prompt text (2240 chars sent vs 1051 real) | notes moved out of scene files; never put prose in a scene file |
| short hair drift | prompt-level: hair was specified in only one of the two places that read it | specified in both the identity block and the face prompt |
| nipple leaks | checkpoint-level (PM25 leaked where PM40 did not, identical text and seed) | negative guards added as belt-and-braces on top of text-cover |
