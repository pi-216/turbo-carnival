# PRD 0001 — Local uncensored brain + the phase machine

> **Status:** CURRENT · draft for founder review · 2026-10-18
> Plan item: **W1.1** · Track: `core-infrastructure` · Owner: unassigned

## Summary

Move the planners (Thinker / Content-Generator / Reviewer) off the hosted, risk-averse model and onto a
**local uncensored model served by llama.cpp on the 4090**, and make the 4090's two tenants — the brain and
ComfyUI — **never co-resident** through an explicit, fail-closed phase machine.

## Problem / motivation

Two independent facts force this, and neither is a preference:

1. **The planners are running on the wrong model.** The existing planning roles sit on a hosted,
   safety-tuned chat model that hedges and refuses briefs that are legal and in-lane. That is the
   "skiddish" failure: the *planning* is timid, while the *render stack* is fine. An uncensored model is
   the fix, and it is the founder's explicit direction.
   *Founder, 2026-10-18:* the same one that replaces them is
   `Qwen3.8-27B-Uncensored-noMTP-Q6_K.gguf`.
2. **The two tenants cannot share the card.** The brain is **22.08 GB** (22,082,529,760 bytes, verified) of
   a 24 GB card; the render graph peaks at **~23 GB**. Each alone nearly fills the 4090. Co-residency is
   impossible, so *something* must sequence them — and today nothing does, because the brain isn't served
   locally at all.

A third fact makes this cheap: **half the machine already exists.** `Growth::SchedulerGate` and
`bin/comfyui_harness.sh` (claim / heartbeat / shutdown / orphan self-heal) already sequence ComfyUI against
the file-based GPU scheduler. What is missing is the *brain* half of the same pattern, and the handoff
between them.

## Goals / Non-goals

- **Goals**
  - The local uncensored model is served on the 4090 by `llama.cpp`, under the same GPU-scheduler claim
    discipline ComfyUI already uses.
  - Brain and ComfyUI are provably never resident at the same time; the handoff is verified, not assumed.
  - The planners can be pointed at the local brain in place of the hosted model.
  - The model artefact lives on shared storage, not in one user's scratch tree.
- **Non-goals (explicit Out)**
  - **Out:** the content of what the Thinker thinks. This PRD builds the *seat*, not the occupant's taste.
  - **Out:** any change to the image stack, the render graph, or the scene/prompt text.
  - **Out:** the Reviewer's vision rubric (its `mmproj` is noted below as available, not specified here).
  - **Out:** any change to the legal floor. It is unchanged and remains the one fail-closed gate.
  - **Out:** the second venue/persona.

## Scope — In / Out

**In:** model staging on the NAS · `bin/brain_harness.sh` · the phase handoff and its VRAM gate · wiring one
planner role onto the local brain as the proof · recording the launch parameters as data.

**Out:** prompt authoring, quality rubrics, LoRA/base-model work, venue B, Instagram surfaces.

## Acceptance criteria

Observable and testable. Each note names the **role** that can verify it, because "the model is fine now"
is not testable by reading code.

```gherkin
Scenario: the brain is resident and a render is requested
  Given the local brain is serving and holds the GPU claim
  When a render is requested
  Then ComfyUI does not start
  And the request parks as a decision row rather than failing
  And the 4090 is never asked to hold both tenants

Scenario: the render phase starts only on measured free VRAM
  Given the brain has been stopped
  When the handoff runs
  Then free VRAM is read from the device, not inferred from process exit
  And the render phase proceeds only if free VRAM >= the declared ComfyUI floor
  And otherwise the batch parks with a reason and no server is started

Scenario: neither harness starts a server without a claim
  Given no GPU claim is held
  When either the brain or ComfyUI harness is asked to ensure a server
  Then it exits 2 and starts nothing
  And the refusal appears as a `*_unclaimed` decision row

Scenario: a legal, in-lane brief is planned without hedging
  Given a brief that is legal and inside the persona's lane
  When the local brain is asked to produce a scene / pose / wardrobe spec
  Then it returns a usable spec
  And it does not refuse, moralise, or substitute a safer brief

Scenario: a render and a review never overlap the brain
  Given a batch has been planned and rendered
  When the review phase begins
  Then the brain is resident and ComfyUI is stopped and verified stopped
```

## User stories / job-to-be-done

- As the **Thinker**, I want a model that will plan in-lane content without hedging, so that the plan
  reflects the persona rather than the model vendor's caution.
- As the **Director**, I want one claim to cover a whole batch, so that yielding the card between phases
  cannot lose it.
- As a **next agent**, I want the launch parameters recorded as data, so that I don't re-derive them by
  trial.

## Edge cases & red lines

- **Never kill a foreign ComfyUI or a foreign GPU tenant.** Ownership rules from the existing harness are
  unchanged: use a running instance untouched; shut down only what we launched.
- **One claim covers the whole batch** (plan → render → review). Yielding between phases risks never
  getting the card back; batching also amortises the model swap.
- **CUDA holds VRAM after process exit.** The gate reads free VRAM from the device; it never trusts an exit
  code as evidence of freed memory.
- **A refused batch is a normal state, not an error.** On a shared card, `vram_insufficient` stays a
  first-class outcome — generalising the existing path.
- **The legal floor is untouched.** Uncensored ≠ explicit: the model writes unhedged; the gate still
  decides what publishes. This PRD changes the writer, not the gate.
- Nothing here is a destructive or external write; no founder sign-off is required to *build* it. The
  **model choice** (below) is a founder call because it sets the plan's tonal range.

## Model staging — verified state

| | |
|---|---|
| the model named by the founder | `/home/tim/source/activity/textgen-4.9/user_data/models/Qwen3.8-27B-Uncensored-noMTP-Q6_K.gguf` — **22,082,529,760 B**, verified present |
| NAS LLM area (exists) | `/mnt/nas-ai-models/LLM/` → `gguf/` holds 12+ GGUFs |
| same family already on the NAS | `…-Uncensored-HauhauCS-Aggressive-Q4_K_P.gguf` (17.92 GB) · `Qwen3.8-27B-UD-Q4_K_XL` (17.56 GB) · `Qwen3.8-27B-UD-Q5_K_XL` (20.88 GB) |
| **vision projector, same family** | `mmproj-Qwen3.8-27B-Uncensored-vision-f16.gguf` (927 MB) — the Reviewer role needs vision; noted, not specified here |
| MTP module on the NAS | `mtp-Qwen3.8-27B-Q4_0.gguf` (1.37 GB) — the named model is explicitly **noMTP** |
| `/mnt/models` | ComfyUI `local_hot`; holds checkpoints/loras/unet/vae/clip only — **no LLM area** |
| llama.cpp | `/home/tim/source/activity/llama.cpp`, HEAD `4df29be4f` (2026-08-16), build 10454, CUDA libs built; `build/bin/llama-server` present |

**The founder's request is "better from the NAS somewhere or `/mnt/models`".** The exact named file is *not*
on the NAS today — the NAS holds siblings — so staging is a real step, and which artefact ends up canonical
is an open question (below).

## Metrics / definition of done

- Both harnesses refuse without a claim, demonstrated by their exit code — not by inspection.
- A full batch completes plan → render → review with the card never double-booked, evidenced by the
  scheduler log and `nvidia-smi` samples taken at each handoff.
- The launch parameters are recorded as data next to the harness (a file, not a memory).
- One planner role runs against the local brain in a real tick.

## Open questions

1. **Which artefact is canonical?** The named `noMTP-Q6_K` (22.08 GB, on local disk) or a NAS sibling
   (`Q4_K_P` 17.92 GB / `UD-Q5_K_XL` 20.88 GB)? Q6_K is the best quality that fits; the Q4s free ~4 GB of
   headroom that the render phase could use. **Founder call** — it sets the plan's tonal range.
2. **Launch parameters are unverified.** Neither `config-user.yaml` nor `config.yaml` in the NAS LLM area
   carries a Qwen3.8-27B entry, and `CMD_FLAGS.txt` is empty. A previously recorded `n_gpu_layers: 65` /
   `cache_type: q4` **could not be re-verified in this pass**, so it is treated as unproven: derive the
   parameters empirically and record them. The hard constraint is that a 22.08 GB model needs a quantised KV
   cache to leave room for context.
3. **Context length.** Long enough for a plan-plus-ledger prompt, short enough to fit beside the weights.
4. **Does the Reviewer get the vision projector from the start**, or is it a second PRD?

---
Drift note (gherkin-specialist): record every deviation when translating this into `.feature` files.
Anything here that cannot be observed is not an acceptance criterion — it is a wish, and the wish goes in
`PROJECT_PLAN.md` instead.
