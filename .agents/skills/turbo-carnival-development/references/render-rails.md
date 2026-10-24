# Render rails: image → motion, and their GPU cost

Sarah's render path is two stages: a persona **image** rail producing the base frame,
then a **motion** rail turning it into a clip. Both are proven to run consistently on
the local box. This file records which workflow is which, what each loads, and the
traps that cost time finding it.

## Workflows (ComfyUI user workflow dir)

| Rail | Workflow file | What it loads |
|---|---|---|
| Persona image (base frame) | `2025-10-08 Sarah srpo flux.json`; older multi-step in `comfy_workflows/sarah1a3/step1_base_image.json` … `step5_upscale.json` | flux / SRPO era, staged base → body → face → hands → upscale |
| **Motion — LTX-2.5** | `lily-video.json` | `ltx-2.5-22b-distilled-transformer-comfy-int8-convrot` + `gemma4-12b-with-proj-ltx-2.5-comfy-int8-convrot` text encoder + `ltx-2.5-video-vae-bf16` + **`ltx-2.5-audio-vae-bf16` + `ltx-av-step-1751000_vocoder_24K`** + `ltx-2.5-latent-spatial-upscaler-x2-bf16` |
| Motion — alt | `Sarahvideo.json` | WAN 2.2 i2v: `wan2.2_i2v_high_noise_14B_fp8_scaled` + `..._low_noise_...` + `wan2.2_i2v_lightx2v_4steps_lora_v1_*` + `umt5_xxl_fp8_e4m3fn_scaled` + `wan_2.1_vae` |

**LTX-2.5 generates synchronised audio** (audio VAE plus a 24 kHz vocoder). Native
sound is a real engagement lever on short-form video — use it, don't discard it.

## Resolving "missing" assets: read `extra_model_paths.yaml` first

`/mnt/fscache/essdee/ComfyUI/extra_model_paths.yaml` sets
`base_path: /mnt/nas-ai-models/`, so a workflow's relative path like `ltxv25/<file>`
resolves under the **NAS model store**, not under the ComfyUI tree — e.g. the VAE lands
at `/mnt/nas-ai-models/vae/ltxv25/`. Before hunting for an asset, read that file; and
read the model filenames straight out of the workflow JSON:

```bash
cd /mnt/fscache/essdee/ComfyUI/user/default/workflows/ \
  && grep -oE '"[^"]*\.(safetensors|ckpt|gguf)"' lily-video.json | sort -u
```

That is far cheaper than walking the model tree, and it also reveals Hugging Face
source URLs embedded in the workflow.

## Traps

- **The LTX text encoder is an embedder, not a chat model — it cannot refuse.**
  Refusals, hedging and moralising come from instruction-tuned *chat* models. Swapping
  "the render stack" to fix skittishness is the wrong target; the uncensored swap
  belongs on the reasoning/authoring roles (planner, generator, reviewer).
- **VRAM: LTX-2.5 cannot co-reside with an LLM on a 24 GB card.** A 22B transformer at
  int8 plus a 12B text encoder alone effectively fills the card. This is why text and
  render work are sequenced rather than run together — the phase machine is a
  requirement, not a preference.
- **The cover frame comes free but must be deliberate.** LTX output lands as a paired
  `<name>.mp4` + `<name>.png` in the output tree. The cover does triple duty —
  scroll-stopper, the frame the platform's classifier evaluates, and the thumbnail —
  so it needs to be specified by the planner and approved by the reviewer independently
  of the clip, not defaulted to frame 1.
- Motion renders are heavier per post than stills (many frames, plus a text encoder),
  so batch sizing changes when the pipeline goes motion-first.
