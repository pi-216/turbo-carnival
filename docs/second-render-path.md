# Second render path — max395 (strix) ComfyUI on ROCm

**Status: install VERIFIED; the PRODUCTION WORKFLOW DOES NOT FIT — memory-blocked (not just
unwired).** Measured 2026-09-23 20:3xZ: the workflow needs **~40 GB of host RAM** and max395 has
**34 GB available** at current co-tenant load, so this host cannot render the pipeline as
configured. Read the "MEASURED footprint" section below before re-proposing this path; it
replaces the 34.4 GB estimate this file carried earlier the same day.

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

Live headroom re-read 2026-09-23 20:3xZ: `Mem total 119 GB, used 84, free 13, buff/cache 22,
available 34 GB`; `GTT Total Used 13.0 GB of 118.1 GB`; largest RSS `llama-server` 66.4 GB.

### MEASURED footprint — from the pipeline's OWN last successful render log

`/mnt/nas-ai-models/gpu-scheduler/logs/comfyui-comfyui-1790060460-2244597-1.log` (2026-09-22
07:08Z, game box) records what the workflow actually loads. This is the authoritative number —
an inventory of the workflow's file references is NOT, because the graph also loads a model the
earlier estimate missed:

```
[INFO] Total VRAM 24080 MB, total RAM 124374 MB
[INFO] model_type FLUX          -> Requested to load Flux
[INFO] loaded partially; 16895.84 MB usable, 16535.69 MB loaded, 6164.44 MB offloaded
[INFO] model_type EPS           -> Requested to load SDXL
[INFO] loaded completely; 6100.50 MB usable, 4897.05 MB loaded, full load: True
[INFO] Requested to load FluxClipModel_ / SDXLClipModel / AutoencoderKL / AutoencodingEngine
[INFO] Prompt executed in 347.09 seconds
```

- The flux UNet is **fp16, ~22.7 GB** (16535.69 loaded + 6164.44 offloaded). `Pipeline 21`'s
  `UNETLoader` carries `weight_dtype: 'default'`, i.e. the file's native dtype — not fp8.
- **The Pony SDXL checkpoint IS loaded** (`Requested to load SDXL` -> 4897 MB resident), together
  with the SDXL VAE and the SDXL CLIP model. It is `checkpoints/pony/Pornmaster_v2551619
  .safetensors` (7.11 GB on disk); the earlier 34.4 GB table omitted both it and the SDXL VAE.
  Verified from the LIVE graph (`pipeline_steps.comfy_workflow_json`, pipeline 21): nodes 43
  UNETLoader, 71 VAELoader(SDXL), 81 DualCLIPLoader, 87 CheckpointLoaderSimple(pony), 90
  VAELoader(ae) — all five reachable from the `SaveImage` terminal.

**Host-RAM requirement of the production workflow ≈ 39–40 GB** (flux fp16 22.7 + t5 fp16 9.8 +
clipL 0.49 + pony SDXL 4.9 + SDXL VAE + flux ae + LoRAs). max395 has **34 GB available**, so it
is **short by ~6 GB**: this is a hard memory gate, not a wiring gap. ComfyUI offloads to host
RAM, it does not compress it — a `--lowvram`-style flag moves weights between VRAM and RAM, it
does not shrink them.

**The ONE in-repo lever that would clear the gate, and its arithmetic.** Setting `Pipeline 21`'s
`UNETLoader` to `weight_dtype: 'fp8_e4m3fn'` removes ~11.4 GB (22.7 -> ~11.3 GB) and lands the
requirement at **~28 GB — it fits.** It is the same weights at lower precision, not a different
model. DECISION 2026-09-23 20:4xZ: **not taken**, because

1. it changes the images the persona pipeline produces, and it cannot be A/B-validated while the
   only capable card is held by the operator (this loop does not ship unverifiable product
   changes);
2. it does not unblock anything on its own — the 4090 path is blocked by the operator's launch
   ARGS (below), and a max395 render additionally needs the remote wiring;
3. the defect it would also blunt (`comfyui-torch-oom`, the fp16 22.7 GB UNet over-committing a
   24 GB card) is already contained by `--reserve-vram` and its board item self-closes.

Trigger to take it: the first time a card we hold is free to validate an fp8-vs-fp16 A/B, or if
max395 becomes the only path. Do NOT take it blind and do not pair it with a host-conditional
variant — two hosts rendering at two precisions would make the corpus heterogeneous and void the
09-28 gate comparison anyway.

Two other levers that were considered and NOT taken:

1. swapping the flux UNet for `Flux1-DedistilledMixTuned.safetensors` (11.9 GB) lands the total at
   **~30 GB — it fits, with ~4 GB margin** — but that is a *different model*, a real product
   change, and the persona LoRAs were trained against flux1-dev. Same decision as the fp8 lever:
   not taken blind.
2. taking a scheduler claim on `strix` does NOT help: the gate is host RAM, and a claim grants
   exclusivity among scheduler users only — it cannot evict the co-tenants.

**Do not launch a ~40 GB load on spec** — the kernel would choose its own victim and it will not
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

**Order matters: wiring alone buys nothing.** Steps 1–4 below do not produce a photo while the
host is ~6 GB of RAM short of the workflow (see the MEASURED footprint section — a lever must be
taken first, and taking one blind is the thing this file forbids). Sized honestly: step 2 is not
a flag but a build — `cmd_ensure`'s GPU, `COMFY_DIR`, `nvidia-smi` probes, the `systemd --user`
unit/cgroup isolation and the heartbeat all assume this box, so a remote mode is a second
lifecycle, not a parameter.

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

## DATED DECISION (2026-09-24) — when the lever stops being optional

The trigger above ("if max395 becomes the only path") was open-ended, so every tick could
re-derive it and none had to decide. The containment depth is now MEASURED — `bin/library_depth.py`
writes `ops/library_depth.json`, `bin/tc_ops.py queue` prints `silence=`, and the board's
`publish-silence-forecast` check escalates on the date — so the trigger has a clock:

| fact | value (measured 2026-09-24 00:3xZ) |
|---|---|
| publish queue dry_out | 2026-09-29T10:30Z |
| GPU-free library depth | **8 spendable photos** = 2.67d at 3/day (of 51 candidates) |
| SILENCE if no render lands | **2026-10-02T02:30Z** — and the library is EMPTY after it |
| the library lever starts firing | when runway < 72h, i.e. ~2026-09-26T10:30Z |

**DECISION: if the 4090 is still blocked at the 72h trigger (~2026-09-26T10:30Z), max395 IS the
only path, and the fp8 lever is taken TOGETHER with the remote wiring** — not the lever alone,
because the lever without the wiring renders nothing; and not later than that date, because after
2026-10-02 there is nothing left to publish at all. The known cost is recorded rather than hidden:
an fp8 UNet is a product change that cannot be A/B-validated while the only capable card is held,
so it would ship on the argument that a slightly heterogeneous corpus beats an empty account (the
09-28 gate cohort is already unmeasurable — 1 post-intervention post of the 5 needed).

Until that date nothing changes: the lever stays untaken, the 4090 path stays preferred, and the
wiring (the long pole — step 2 above is a build, not a flag) starts at the trigger, which leaves
~6 days of margin before silence.

