# Lily vs Sarah — hand inpainting comparison

> **Status:** REFERENCE — comparison only; concluded the inpaint paths are equivalent

Source: `turbo-one-step-Lily.json` (canvas format, saved 2026-10-17) vs
`comfy_workflows/turbo_one_step_v2/step1_generate.json` (API format).
Tooling: `scripts/dump_canvas_workflow.py`, `scripts/compare_hand_paths.py`,
`scripts/trace_lily_pose.py`, `scripts/trace_lily_final.py`.

**Method note.** The canvas file carries its own parameter NAMES (`inputs[].widget`), so values are
paired by name, never by position. Both files carry their names explicitly; no positional guessing.

## The hand/face INPAINT path is nearly identical

| parameter | Sarah | Lily | same? |
|---|---|---|---|
| graph topology | 2 CLIPSeg, 2 grow, 4 crops, 2 blends, 2 switches | identical | **yes** |
| CLIPSeg prompt (hand) | `hand` | **`hands`** | **NO** |
| CLIPSeg threshold | 0.4 | 0.4 | yes |
| CLIPSeg dilate / blur / smooth (hand) | 10 / 10 / 10 | 10 / 10 / 10 | yes |
| mask grow `expand` | 20 | 20 | yes |
| mask grow `blur_radius` | 7.800000000001095 | 7.800000000001095 | yes |
| crop padding — face (nodes 10/11) | **85.43** | **64** | **NO** |
| crop padding — hand (nodes 30/64) | **9.75** | **64** | **NO** |
| blend `feathering` (both passes) | 10 | 10 | yes |
| blend `blend_factor` (both passes) | 1 | 1 | yes |
| `ImageResize+` canvas target | 1024 | 1024 | yes |
| hand scheduler steps / denoise | 25 / **0.68** | 25 / **0.68** | **yes** |
| face scheduler steps / denoise | 35 / **0.66** | 35 / **0.70** | **NO** |
| `LazySwitchKJ` switch | False (hardcoded) | False (hardcoded) | yes |
| hand pass conditioning | FluxGuidance 3.5 ← Text Multiline `Young female arm and hand` | identical | yes |

**So the hand inpaint differs in exactly two settings: the CLIPSeg prompt (`hand` vs `hands`) and the
crop padding.** Everything else in that path — denoise, mask grow, blends, canvas size, conditioning —
is the same.

**And the padding difference points the WRONG way to explain Lily.** Lily runs **64** on the hand crop.
E4 tested exactly that direction on Sarah (9.75 → 48) and the **baseline won the hands axis in every
pair where a hands opinion was given**. So on the one axis that is directly comparable, Lily sits on the
side that measured worse for Sarah. **The inpaint path is therefore excluded as the explanation** for
"fewer hand issues at that persona".

## What actually differs — all of it OUTSIDE the inpaint path

| area | Sarah | Lily |
|---|---|---|
| **base pose control** | none | **`controlnet-openpose-sdxl-1.0`, strength 1, `0 → 0.27` of steps, on the Pony base** |
| pose control image | — | `LoadImage` → **`7-pose-B.png`** (a pose MAP file, not a render) |
| OpenPose extractor | absent | `OpenPose - Get poses` on the reference (node 243) → **`PreviewImage` only — not wired into the pipeline** |
| base sampler | `KSampler` 96: **125 steps, cfg 5.5** | `KSampler` 96: **140 steps, cfg 7**, dpmpp_2m/karras, denoise 1 |
| base positive | the long identity block (node 88) | **`score_9, score_8_up, score_7_up, solo, breasts`** (short) |
| Pony LoRA stack | sarah1a3 0.8, sk1nny 0.8, skin slider 0.65, add-more-details 0.65 | **sarah1a3 0.9**, **`sk1nny…-000004`** (different file), **Pony Realism Slider 0.75**, **`body_weight_slider_v1` 0.6**, **`Breast Sag Slider` −1**, **`BustyFC-pdxl` −0.3** |
| flux LoRAs | sarah1a3 1.0, flux_realism 1.0, **`tg` OFF** | `flux/L1ly` 1.0, flux_realism 1.0, **`tg` ON @ 0.6** |
| upscale | none | **4x_foolhardy_Remacri → ImageScaleBy 0.25** |
| geometry | 816 × 1024 | 832 × 1216 |
| torch.compile | **`TorchCompileModel` present** (source of the Dynamo failures) | **absent** |
| mask-empty guard plumbing | present but **dangling** (`GetMaskSizeAndCount`→`Int To Number`→nowhere; `Constant Number`=0; `LazySwitchKJ.switch` hardcoded False) | **absent entirely** |

Founder confirmation (2026-10-18): *"the openpose in Lily only feeds into Pony, not the face/hand
inpaint."* The trace agrees: `ControlNetApplyAdvanced` (235) → `KSampler` (96) only.

## The conclusion, and why it is coherent

Lily generates its base in the pose of **a real photograph** (a chosen pose map, at strength 1 for the
first 27% of steps); Sarah generates its base from **text alone**, i.e. from Pony's own pose priors.

That is a mechanism for exactly the symptom: "Pony's hands are not the greatest" because the *pose*
is unconstrained, so the hands are invented from priors and then the inpaint is asked to repair
invention. Constrain the pose from a real image and the anatomy is already coherent — the inpaint only
has to refine. **The fix is upstream of every inpaint knob, which is why tuning those knobs (E4) moved
nothing useful.**

## Next axis (agent decision)

**Pose-constrained base generation.** Add the openpose ControlNet to the base pass and compare against
the unconstrained base, holding scene, seed, checkpoint, prompting and the whole inpaint path fixed.

**Guard note:** this is a *structural* change, not a single leaf, so the E4 leaf-diff assertion does not
apply. The equivalent guard is a **scope assertion**: assert that every inpaint-path node (mask prompts,
thresholds, grow, crops, blends, schedulers, conditioning, canvas targets) is **byte-identical** between
the two arms, and that the only additions lie on the base-pass path. Report that as the one-axis
evidence.

## Assets confirmed available (2026-10-18)

Lily's saved graph **is runnable**. Models resolve through `extra_model_paths.yaml` — `local_hot` →
`/mnt/models/`, `nas` → `/mnt/nas-ai-models/`, `comfyui_local` → the ComfyUI tree itself. Verified:

- `controlnet-openpose-sdxl-1.0.safetensors` — 2,502,139,104 bytes, in `/mnt/nas-ai-models/controlnet/`
  (so the empty `…/ComfyUI/models/controlnet/` is a red herring: the `nas:` block supplies it).
- `4x_foolhardy_Remacri.pth` — 67,025,055 bytes, in `/mnt/nas-ai-models/upscalers/`.
- `7-pose-B.png` — present in `ComfyUI/input/`, alongside **4,491** pose-map files.

**Lesson for this repo:** do not conclude a model is missing from the local `models/` tree. Use the
exact paths declared in `extra_model_paths.yaml` and `ls` them directly; a recursive `find` across the
NAS mounts can time out and return a **false negative**.

## An independent, cheap win found in the same diff

**Sarah's graph carries `TorchCompileModel`; Lily's does not.** Every Dynamo/SDPA failure in this
project's failure table (`cyberrealisticPony_v180Coreshift`, node 96) comes from the compiled path.
Lily runs the same architecture without it and has no such failures. Removing `TorchCompileModel` is a
**one-node removal that deletes an entire failure class**, at a speed cost. That is its own single-axis
change, validated on its own — not bundled with E5.

**Also already proven in the field:** Lily runs `pony/body_weight_slider_v1` at **0.6** — that is E1's
axis, in a configuration the founder says works well. E1 (filed, never run) therefore has a prior that
the slider is at least not harmful, and a value (0.6) that already has mileage.

## A pattern worth naming: both graphs are one connection short

- **Sarah**: the empty-mask bypass is fully built — `GetMaskSizeAndCount` → `Int To Number` → *nowhere*,
  two `Constant Number` = 0 dangling, and both `LazySwitchKJ.switch` inputs hardcoded `False`.
- **Lily**: `OpenPose - Get poses` extracts a pose and feeds only a `PreviewImage`; the ControlNet takes a
  **manually chosen pose-map file** (`LoadImage` → `7-pose-B.png`) instead.

Both are the same shape of latent defect: **the feature is built, verified in isolation, and then left one
connection short** — so it looks present on the canvas while doing nothing. When auditing a graph here,
trace the links rather than trusting the node list.
