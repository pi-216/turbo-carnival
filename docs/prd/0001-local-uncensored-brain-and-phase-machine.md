---
venture: turbo-carnival
source: PROJECT_PLAN
---

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
| **staged artefact (destination)** | `/mnt/nas-ai-models/LLM/gguf/Qwen3.8-27B-Uncensored-noMTP-Q6_K.gguf` — staged by #23, **sha256 read back and matched** (`4856b645…2118b10`); recorded as data in `config/autonomous/brain.yml` |
| NAS LLM area (exists) | `/mnt/nas-ai-models/LLM/` → `gguf/` holds 12+ GGUFs |
| **uncensored** sibling on the NAS | `…-Uncensored-HauhauCS-Aggressive-Q4_K_P.gguf` (17.92 GB) — a *different tune* (HauhauCS "Aggressive"), declares `vision` + `mtp` |
| **vanilla** siblings on the NAS | `Qwen3.8-27B-UD-Q4_K_XL` (17.56 GB) · `Qwen3.8-27B-UD-Q5_K_XL` (20.88 GB) — verified `general.name = Qwen3.8-27B` (Unsloth), **not uncensored**. These are the hedging model this PRD exists to replace and are **not** candidates for this seat |
| **vision projector, same family** | `mmproj-Qwen3.8-27B-Uncensored-vision-f16.gguf` (927 MB) — the Reviewer role needs vision; noted, not specified here |
| MTP module on the NAS | `mtp-Qwen3.8-27B-Q4_0.gguf` (1.37 GB) — the named model is explicitly **noMTP** |
| `/mnt/models` | ComfyUI `local_hot`; holds checkpoints/loras/unet/vae/clip only — **no LLM area** |
| llama.cpp | `/home/tim/source/activity/llama.cpp`, HEAD `4df29be4f` (2026-08-16), build 10454, CUDA libs built; `build/bin/llama-server` present |

**The founder's request is "better from the NAS somewhere or `/mnt/models`".** The exact named file was *not*
on the NAS — the NAS held siblings — so staging was a real step. **It is staged** (#23): the artefact now sits
at `/mnt/nas-ai-models/LLM/gguf/Qwen3.8-27B-Uncensored-noMTP-Q6_K.gguf`, its sha256 verified against the source,
and the path is recorded as data in `config/autonomous/brain.yml`. The canonical artefact was decided by the
founder on 2026-10-19 (open question 1, below).

## Metrics / definition of done

- Both harnesses refuse without a claim, demonstrated by their exit code — not by inspection.
- A full batch completes plan → render → review with the card never double-booked, evidenced by the
  scheduler log and `nvidia-smi` samples taken at each handoff.
- The launch parameters are recorded as data next to the harness (a file, not a memory).
- One planner role runs against the local brain in a real tick.

## Open questions

1. ~~**Which artefact is canonical?**~~ **RESOLVED — founder ruling, 2026-10-19.**
   **Canonical: `Qwen3.8-27B-Uncensored-noMTP-Q6_K.gguf`** (`general.name = "Abl 27b"`, abliterated;
   22,082,529,760 B / 20.57 GiB). The NAS siblings are **not** alternatives for this seat.
   Reasoning, in the order it decided the call:
   - **The headroom argument for a Q4 is void.** The phase machine exists so the brain and ComfyUI are
     never co-resident, so the ~4 GB a Q4 releases can never be used by the render phase. The PRD's own
     headline reason for preferring a Q4 does not survive its own design.
   - **Context cannot break the tie either.** This is a hybrid model — `qwen35`, 64 blocks,
     `full_attention_interval = 4`, so only **16** layers hold a KV cache and the other 48 are SSM
     linear-attention with a context-independent state. KV is **64 KiB/token at f16**. Against the
     measured 23.02 GiB free, Q6_K leaves a 1.56 GiB KV budget → **~25.6 K tokens at f16 KV**, ~51 K at
     q8, ~102 K at q4. A plan-plus-ledger prompt is a few thousand tokens. The tightest candidate is not
     tight.
   - **Two of the three "siblings" are the vanilla model, not alternatives.** `Qwen3.8-27B-UD-Q5_K_XL`
     and `UD-Q4_K_XL` read `general.name = Qwen3.8-27B` (Unsloth quants, no `uncensored` tag). They are
     the hedging model this PRD exists to replace. Struck from the candidate list.
   - What remains is fidelity, and Q6_K is two quant steps above the Q4_K_P.
   The one condition that would have reversed this: if the Reviewer's vision role rides *this* artefact
   (open question 4), `…Uncensored-HauhauCS-Aggressive-Q4_K_P` is the only candidate declaring `vision`.
   Noted, not chosen — it stays available for a separate vision seat.
2. ~~**Launch parameters are unverified.**~~ **RESOLVED — measured, ticket #26 (2026-10-19).**
   The previously recorded `n_gpu_layers: 65` / `cache_type: q4` was never re-verifiable and is **not**
   used. A five-config matrix was run on the 4090 under one scheduler claim (device VRAM sampled at
   `/health`), and the chosen parameters are recorded as data in `config/autonomous/brain.yml`
   (`serving:`), each with the VRAM it cost. **Chosen: `n_gpu_layers: 999`, `ctx_size: 32768`,
   `cache_type_k/v: q8_0`, `batch_size: 2048`, `ubatch_size: 512`** → **22863 MiB used / 1218 MiB free**
   at a 439 MiB baseline (the largest context at the highest KV fidelity that leaves ≥ 1 GiB). A cold
   start from the recorded parameters succeeded (up in 5s), served a real completion, and shut down
   clean (port closed, GPU idle, claim released).
3. ~~**Context length.**~~ **RESOLVED by #26.** `32768` — it fits with ≥ 1 GiB free and is ~5× the
   plan-plus-ledger prompt (a few thousand tokens). Smaller contexts (16 K at 1842 MiB free, 8 K at
   2144 MiB free) are measured and recorded in `brain.yml` for a downgrade, but the seat needs neither.
4. **Does the Reviewer get the vision projector from the start**, or is it a second PRD?

## Planner cadence — founder ruling (2026-10-19)

**The planner runs once a night.** The brain owns the 4090 for one bounded nightly planning window
(plan → render → review under a single claim, per the phase machine above); it does not contend with
the hourly cadence tick. This is the ruling the local-brain routing needed, because the seat is
~22.3 GiB of a 24 GiB card and cannot be resident at tick time.

Consequences, so the next agent does not re-derive them:

- The **hourly** loop stays on the host (snapshot, cadence top-up, publish) and does **not** need the
  brain. It calls the brain only through the in-app planner path (#27), which is pull-based and
  returns template suggestions if the seat is down — so the day-to-day flow never waits on it.
- The **nightly** window is where a planning prompt may be issued against the seat; it takes the
  claim once and yields nothing between phases (PRD 0001 Director story).
- Pointing the growth cron agent's model at the local endpoint is therefore a **nightly** job, not an
  hourly one. Any such cron must be pinned to provider+model (an unpinned job drift-skips silently).

## The pillar set is fair game — founder ruling (2026-10-19)

**"The brain or experimenter should know that the existing pillars are fair game."** Recorded verbatim.

The planner's remit is therefore **not bounded by the pillars that exist today**. It may propose a change to
the content-pillar set itself — reweight, retire, replace, rename, split, or add one — and not only clusters
*inside* a pillar, which is the only thing the nightly plan can emit today (`brain:plan` iterates
`persona.content_pillars.current` and proposes per pillar; see `Growth::NightlyPlanner`).

Consequences, so the next agent does not re-derive them:

- **The pillar set is class 2** (`AGENTS.md` → *the authority ladder*): the system acts, measured. It is not a
  founder rail, and the five rails in `THESIS.md` are untouched by this ruling.
- **The change path is the existing bounded one.** `Growth::PersonaEvolution` is the only writer of a pillar's
  `weight`/`priority`/`active`; it steps one delta within hard caps and its pre-registered gate auto-reverts a
  change that fails at the next review. "Fair game" licenses *changing a pillar through that ledger* — never
  an unrecorded edit, which is the shape the ledger exists to make impossible.
- **What a pillar depicts is not in scope.** Intensity stays class 3 and the age read stays class 4: this
  ruling moves the *mix*, never the wardrobe ladder or the persona identity.
- **A pillar's name is not a schema.** `Growth::PillarPrompt` resolves a scene bank from the pillar name and
  falls back to a default pool for a name it does not know, so a renamed or newly added pillar renders from
  the default pool until its bank is added — a gap in variety, not a crash.

---
Drift note (gherkin-specialist): record every deviation when translating this into `.feature` files.
Anything here that cannot be observed is not an acceptance criterion — it is a wish, and the wish goes in
`PROJECT_PLAN.md` instead.
