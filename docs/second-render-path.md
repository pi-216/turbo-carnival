# Second render path — max395 (strix) ComfyUI on ROCm

**Status: feasibility VERIFIED (2026-09-23), wiring NOT done.** This file exists so the
next agent (or a human) does not re-probe what is already measured.

## Why this exists

The render loop has exactly ONE host: ComfyUI on the game box's 4090. `Growth::LibraryFallback`
records the consequence — `render-starved` holds of **1.5–96 h, recurring since 2026-08-16**,
whenever another project's supervisor or the operator's own session occupies that card (a
foreign instance launched without `--reserve-vram` is refused on launch ARGS before any
scheduler claim is even asked for). A single-host render path makes the whole content loop
dependent on somebody else's GPU window. A second host removes the dependency.

## What is measured (all read live, 2026-09-23 ~19:40–20:00Z)

**CORRECTION to the 2026-09-23 18:4xZ ops note** ("max395: ComfyUI is not installed there —
only a stray custom_nodes, no main.py, no venv"): **that is wrong for `~/activity/ComfyUI`.**

| fact | value |
|---|---|
| install | `/home/tim/activity/ComfyUI` — git repo (HEAD 99073836, 2026-09-20), `main.py` present, `.venv` (python 3.14.7) |
| stack | `torch 2.12.0a0+rocm7.13.0a`, `hip 7.13.60980`, `torch.cuda.is_available() == True` |
| device | `cuda:0 Radeon 8060S Graphics : native` — `vram_total` 118.1 GB (GTT), `vram_free` 64.4 GB |
| server | starts and serves: `{"comfyui_version": "0.36.0", "queue_running": [], "queue_pending": []}` on `:8188` |
| custom nodes | comfyui-clipseg, comfyui-impact-pack, ComfyUI_IPAdapter_plus, was-ns, comfy-mtb, comfyui-ollama (the CLIPSeg/Impact family the turbo-one-step workflow uses) |
| prior renders | `~/activity/ComfyUI/output/` holds real renders (SD1.5, `prose-*`, Aug 9) — the stack has executed graphs before |
| model paths | `extra_model_paths.yaml` maps the shared NAS `/mnt/nas-ai-models/` (checkpoints, clip, unet, vae, loras, upscale_models, …). No `/mnt/models` (that is the game box's local hot SSD) |

**Model inventory for the actual pipeline.** `Pipeline 21` (`turbo-one-step-clean`,
`pipeline_steps.workflow`) references, and every one of them resolves from max395:

| workflow ref | resolves to | present |
|---|---|---|
| `flux1/flux1-dev.sft` | `/mnt/nas-ai-models/unet/flux1/flux1-dev.sft` (23.8 GB) | yes |
| `t5xxl_fp16.safetensors` | `/mnt/nas-ai-models/clip/t5xxl_fp16.safetensors` (9.8 GB) | yes |
| `clipLFullFP32Zer0int_textImprovedFP32.safetensors` | `/mnt/nas-ai-models/clip/…` (0.49 GB) | yes |
| `ae.safetensors` | `/mnt/nas-ai-models/vae/ae.safetensors` (0.34 GB) | yes |
| `flux/sarah1a3.safetensors` | `/mnt/nas-ai-models/loras/flux/sarah1a3.safetensors` (0.34 GB) | yes |
| `flux/flux_realism_lora.safetensors` | `/mnt/nas-ai-models/loras/flux/...` (22 MB) | yes |
| `flux/tg.safetensors` | `/mnt/nas-ai-models/loras/flux/tg.safetensors` (0.17 GB) | yes |

*Known cosmetic defect in max395's `extra_model_paths.yaml`: `text_encoders: text-encoders/`
points at a directory that does not exist (the NAS dir is `text_encoders/`). Harmless for this
workflow because T5 is loaded through the `clip` mapping — but it will fail any node that asks
for the `text_encoders` bucket.*

## The one remaining gate: memory, sized against CO-TENANTS on max395

max395 is a **shared** box; it hosts other projects' resident services:

| co-tenant | footprint |
|---|---|
| `llama-server` (Qwen3.8-27B, port 8080, `-ngl 99`) | ~70 GB RSS, iGPU offload |
| `image_embed` uvicorn (evergreen) | ~5.6 GB RSS |
| ollama `llama-server` (caption endpoint, `:11434`) | ~1.6 GB RSS |
| `rocm-smi --showuse` | iGPU 100 % busy at probe time |

Live headroom at probe time: `ram_free` 29–32 GB, `GTT free` 64 GB, swap 8 GB (65 MB used).

The workflow's weight footprint is **~34.4 GB fp16** (23.8 + 9.8 + 0.49 + 0.34 + LoRAs), which
**does not fit** in ~30 GB of free RAM alongside those services. Options, in order:

1. render at the smaller FLUX unet already on the NAS (`Flux1-DedistilledMixTuned.safetensors`,
   11.9 GB → ~22.4 GB total footprint, fits) — but confirm the persona LoRAs still behave;
2. keep fp16 and take a scheduler claim on `strix`, then size the ask against live free GTT;
3. wait for the co-tenants to free RAM.

**Do not launch a 34 GB load on spec** — the kernel would choose its own victim and it will not
be ours (`llama-server` is the largest process on the box).

## How to bring the host up (verified commands)

```bash
ssh -o BatchMode=yes tim@192.168.86.137 \
  "bash -lc 'cd ~/activity/ComfyUI && nohup .venv/bin/python main.py --listen 0.0.0.0 --port 8188 \
   >> /tmp/comfy_tc.log 2>&1 & sleep 3; echo launched'"
ssh tim@192.168.86.137 "bash -lc 'curl -s -m 10 http://127.0.0.1:8188/system_stats | head -c 600'"
```

Notes: the remote login shell is **fish** — always wrap payloads in `bash -lc '…'`. The SSH call
returns before ComfyUI is listening; poll `/system_stats` instead of trusting the return.
Stop it by PID (`pgrep -af "[m]ain.py --listen"` on that host) — it is not under our harness.

## What wiring still requires (agent-owned, not a Tim ask)

1. **Render submission against a remote base URL.** `config/initializers/comfyui.rb` reads
   `COMFYUI_BASE_URL` (default `http://localhost:8188`) and `SubmitJob` posts the workflow there,
   so the *submission* half is already host-agnostic. `PollJobStatus`/`ProcessJobResult` read
   results back through the same client — verify each against a remote host before trusting it.
2. **The harness is local-only.** `bin/comfyui_harness.sh` (`cmd_ensure`, the `--reserve-vram`
   args gate, `vram_ask_for_free`, the co-tenant attribution, the claim lifecycle) assumes the
   GPU is on this box. A remote mode must not weaken that gate for the 4090 path.
3. **Scheduling.** max395 has co-tenants, so a render there should hold a scheduler claim
   (`--gpu strix`) like any other GPU job, with the heartbeat probing ROCm
   (`rocm-smi --showmeminfo all`, GTT not VRAM) over SSH.
4. **Co-existence.** The failure mode to guard is *our* render starving the caption endpoint or
   the other projects' services on the same unified-memory box. Size from live free RAM, and
   check the resident set at claim time, not from a constant.
