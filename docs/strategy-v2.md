# turbo-carnival v2 — Strategy

> **Status:** CURRENT — distribution diagnosis, venues, platform findings — its §8–13 process sections are superseded by docs/strategy-v3.md

*Supersedes the content-strategy portion of `THESIS.md`. **Two red lines in `THESIS.md` are formally
revised — see §5 and §12.**

The original caveat *"nothing here is built yet"* is now stale and has been removed: the render rail
(`comfy_workflows/turbo_one_step_v2`), the experiment harness, the content board and the mask guard all
exist — see `PROJECT_PLAN.md` for what is built, what is paper, and in what order.*

---

## 0. Decisions locked in this session

| # | Decision | Source |
|---|---|---|
| 1 | Audience values **visual gain over personality** — content is not built on character/story | founder |
| 2 | **Two venues**: Instagram = SFW discovery funnel; a permissive platform = explicit payload | founder |
| 3 | Instagram stays **safe-side** (account is tied to a personal account; blast radius matters) | founder |
| 4 | The intensity limits get probed by a **separate, isolated persona** — not Sarah | founder |
| 5 | **Keep** Instagram account `a1.sarah.a1` (161 followers, keep the history) | founder |
| 6 | Uncensored text model runs **on this box (4090)** via llama.cpp, as a **phase machine** | founder |
| 7 | **Bounded autonomy** — Thinker proposes; founder approves *direction changes* only | founder |
| 8 | Goal is **growth in general**, not a single vanity number | founder |
| 9 | Both render rails (persona image template; LTX-2.5 motion template) are **proven consistent on this box** | founder |

---

## 1. Diagnosis — the binding constraint is distribution, not content

The repo already found this on 2026-09-24 (`Growth::ReelBuilder` header), built the
reel rail, published **exactly one reel**, then went back to statics. The platform's
own insights data settles it:

| Window | Posts | Non-follower reach | Total reach | Profile views |
|---|---|---|---|---|
| Oct 9–11 | static | **0** | 4–5 | 0 |
| **Oct 12** | **1 reel** | **6** | **13** | — |
| Oct 13–14 | static | 7–8 | 15–16 | **9** |
| Oct 15–18 | static | 1 | 8–9 | ~1 |

- **344 static posts produced zero non-follower reach, ever.** Not low — *zero*.
- The single reel produced **4× reach**, the **only profile views this account has
  ever recorded**, and +2 followers.
- All-time peak followers 188; currently 161. Flat-to-declining for a month.
- **11 of 345 posts carry a reel.** 64 posts are `failed` with **no `failure_reason`
  recorded** — a blind spot.

**Conclusion.** Every content lever the old harness tuned (captions, hashtags, pillar
weights, cadence, posts-per-day) was **inert by construction** — it cannot move a
number that is zero on a surface with no discovery step. 278 posts bought ~10
followers because nobody was shown them. The rebuild is a **distribution correction
plus a venue split**, not a content brainstorm.

*Caveat: the reel result is n=1. It is treated as the strongest available signal, not
as proof — the ledger should record it as a hypothesis with a pre-registered
evaluation, not as an established effect.*

---

## 2. Architecture — two venues, one machine

The core tension: **the audience this persona targets is served by content that
Instagram's recommender penalises.** Wholesome content gets distributed; borderline
content gets suppressed. Fighting that inside Instagram is unwinnable.

Resolution: **stop fighting it.** Split the estate by venue.

```
┌─ VENUE A — DISCOVERY (SFW) ─────────────────────────────────────┐
│  Instagram (primary) · X (candidate secondary)                  │
│  Sarah · safe-side · reels-first                                │
│  Instrument: NON-FOLLOWER REACH                                 │
└───────────────────────────┬─────────────────────────────────────┘
                            │ funnel through a NEUTRAL interstitial
                            │ (never a direct explicit link)
┌───────────────────────────▼─────────────────────────────────────┐
│ VENUE B — PAYLOAD (explicit, paywalled)                         │
│  Fanvue · SECOND persona · fully isolated identity              │
│  Public discovery surface stays SFW (platform requirement)      │
└─────────────────────────────────────────────────────────────────┘
```

This converges platform rules with risk posture: **both** demand a SFW public surface
with the explicit material behind a paywall. The safe architecture and the compliant
architecture are the same architecture.

---

## 3. Platform findings (researched 2026-10-18)

| Platform | Fully synthetic persona | Photoreal AI adult | Verdict |
|---|---|---|---|
| **Fanvue** | ✅ recognised, verified category | ✅ allowed, must be labelled | **PAYLOAD VENUE** |
| **X / Twitter** | ✅ adult + AI-generated explicitly allowed | ✅ with labelling | candidate discovery |
| OnlyFans | ❌ terminate | ⚠️ own likeness only | **out** |
| Fansly | ⚠️ non-photoreal only | ❌ banned | **out** (photoreal) |
| Patreon | ⚠️ illustrated/animated | ❌ needs real adult's consent | **out** |

**Rules that constrain the design**

- **Fanvue** — mandatory prominent disclosure (bio / caption / watermark); **public
  discovery media must be SFW** (profile picture, banner, intro video); no under-18
  cues, including "seems underage"; operator must complete real-identity verification;
  explicit content allowed when labelled and paywalled. ⚠️ **Unverified: at least one
  source reports Fanvue restricted AI-driven chat/DM automation** — confirm against
  current policy *before* designing any engagement automation.
- **X** — adult content permitted when labelled; AI-generated adult content needs a
  **separate** AI-disclosure label on top of the sensitivity tier. **Prohibited in
  profile picture or banner.** Prohibits manufactured identities used *deceptively*,
  plus aggressive automation and link-only promotion — the funnel mechanics must be
  clean.
- **Universal floor** — CSAM, non-consensual intimate imagery, and non-consent are
  prohibited everywhere. This is already project red-line material.

---

## 4. Blast-radius isolation (founder priority)

Isolation is **architectural, not procedural** — enforced by structure, not by
remembering to be careful.

- A **separate persona** for Venue B: different look, different voice, different
  name. It is a **probe** — a canary that finds the platform limits. Sarah's IG
  account never approaches the edge.
- **Separate credentials**: email, phone, payment, and platform logins. No shared
  secrets between venues.
- **No cross-linking**: different handles, no shared watermark, no shared link-in-bio
  or Linktree, no shared bio text, no shared browser/app session.
- **Neutral interstitial** between Venue A and Venue B (Instagram's
  sexual-solicitation rules penalise direct links to explicit paywalls).
- **Separate job namespaces and venue config rows** in the harness — the two personas
  must not share a code path that can leak state, credentials, or assets.

---

## 5. Estate-wide invariants (red lines, restated)

- **Legal floor**: unambiguous adult; no minor cues; no real-person likeness without
  documented consent; machine-readable synthetic mark on **every published asset**.
  *This is now both a legal and a business requirement* — both venues enforce it
  independently.
- No destructive, irreversible, or external write without founder sign-off.
- Never launch ComfyUI unclaimed or blow the GPU budget.
- **Uncensored ≠ explicit.** The model *writes* unhedged; the *gate* decides what
  publishes. These must never be conflated.
- **Gates vs controls** (founder, 2026-10-18): quality controls — human rating,
  identity similarity, genetic search — are **instruments and selectors, never
  blockers**. The single exception is the **legal floor**, which stays a hard
  fail-closed gate. "Safe side" on Instagram and blast-radius isolation are
  unchanged.

---

## 6. Where the uncensored model belongs

**A clarification that matters.** LTX-2.5's text encoder is a Gemma-4-12B model — it is
an *embedder*. Embedders do not refuse. Skittishness lives in **instruction-tuned chat
models**, which hedge, moralise, and refuse. So the uncensored swap targets the
**reasoning and authoring roles**, not the render stack.

| Role | Job | Notes |
|---|---|---|
| **Thinker** | Owns an audience model + written hypothesis ledger; emits briefs | The growth engine. Does not exist today — `StrategyBrain` is a numeric thermostat. Needs uncensored most. |
| **Content-Generator** | brief → explicit scene/pose/wardrobe/framing spec + **named cover frame** + caption | Must not grade its own output. |
| **Reviewer** | Two rubrics: (a) does it land, (b) **will the platform distribute it** (cover-frame classifier risk) + identity + realness + legal floor | Replaces the AVA/sharpness gate that passed 6–7 on imagery the founder deleted by hand. |
| **Director** | Sequences phases, owns retries and batch composition | |

**The brain is the uncensored model (founder, 2026-10-18).**
`/home/tim/source/activity/textgen-4.9/user_data/models/Qwen3.8-27B-Uncensored-noMTP-Q6_K.gguf`
(**22.08 GB**). Confirmed viable on the 4090 by its existing text-generation-webui
config: `gpu_layers: 65` (all layers) with `cache_type: q4` — the quantised KV cache is
what makes a Q6_K 27B fit. **22.08 GB of 24 GB leaves ~1.9 GB, so this model and ComfyUI
can never be co-resident** — which is independent confirmation that the phase machine is
mandatory, not a preference.

Consequences:
1. **The brain is now a GPU tenant.** It can only run in the THINK/JUDGE phases, so the
   whole loop must be phase-aware — including anything cron-driven.
2. **The recurring inference-capacity blocker disappears.** `brain-gateway-failed`
   (max395 ds4 saturation) and OpenRouter dependency both go away — the driver is local.
3. ⚠️ **Capability trade-off to weigh:** a 27B dense local model is markedly weaker at
   agentic orchestration and tool-calling than DeepSeek 4.1 Flash. Whether the local
   model *drives orchestration* or only owns *creative direction, prompts, captions and
   review* is a capability question, not a censorship one — worth a deliberate call.

**The Reviewer needs vision.** The only **uncensored** VLM available is
`Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive` (Q4_K_M + `mmproj`, MoE with 3B active
— fast). Its base GGUF is in the HF cache; Ollama's `qwen3-vl:32b` is safety-tuned.

**New job type: `cover_frame`.** The cover does **triple duty** — the scroll-stopper,
the classifier's evidence, and the thumbnail. It must be *rendered deliberately*, never
picked as frame 1. The Reviewer must approve the cover independently of the clip.

---

## 7. Render phase — what actually runs (verified assets)

| Rail | Workflow | Stack |
|---|---|---|
| Persona image | Sarah flux/SRPO template | base frame |
| **Motion (LTX-2.5)** | `lily-video.json` | `ltx-2.5-22b-distilled-transformer-comfy-int8-convrot` + `gemma4-12b-with-proj-ltx-2.5-int8` text encoder + video VAE + **audio VAE + vocoder** + latent spatial upscaler ×2 |
| Motion (alt) | `Sarahvideo.json` | WAN 2.2 i2v 14B fp8 high/low noise + lightx2v 4-step LoRAs + umt5-xxl |

- Models resolve through `extra_model_paths.yaml` (`base_path: /mnt/nas-ai-models/`).
- **LTX-2.5 can generate synchronised audio** (audio VAE + 24 kHz vocoder) — **but do
  NOT use it** (founder, 2026-10-18). Render video only; skip the audio path.
- Image stack (founder-owned R&D, 2026-10-18): hand-mixed
  `/mnt/nas-ai-models/checkpoints/pony/CRPv18_PM25.safetensors` or `CRPv18_PM40.safetensors`
  with **flux1-dev inpainting on face and hands**. The flux face pass is the mitigation
  for the exact failure the old red line was written about — see §12.
- LTX-2.5 (22B int8 + 12B text encoder) **cannot coexist with a resident LLM** on a
  24 GB card. This independently confirms the phase machine is required, not optional.

---

## 8. Producer pipeline — phase machine

```
THINK   (llama.cpp resident, uncensored)
        brief → concept → prompt_spec ×N → cover_frame spec ×N → captions
   ↓ handoff: flush KV, stop server, VERIFY free VRAM ≥ floor      [fail-closed]
RENDER  (ComfyUI resident — ONE scheduler claim covers the whole batch)
        render N clips (image → LTX-2.5) + N deliberate cover frames → import
   ↓ handoff: stop ComfyUI, release claim, verify port closed
JUDGE   (llama.cpp / VLM again)
        score each render vs brief → accept / reject+reason → ledger
```

Three design truths:

1. **One claim covers the whole batch.** Yield the card between THINK and RENDER and
   you may never get it back.
2. **Handoffs are read, not assumed.** CUDA holds VRAM briefly after process exit —
   free-VRAM from `nvidia-smi` is the gate.
3. **Batch to amortise the swap.** All LLM work → all renders → all reviews.

The 4090 is shared (23.4 GB in use by other projects at time of writing), so **"batch
refused, keep the trigger firing" is a normal, expected state** — the existing
`vram_insufficient` path generalised.

**Four layers, permanently unfused:**

| Layer | What it is | Rule |
|---|---|---|
| Trigger | what makes work *wanted* | schedule / event / threshold → **emits** jobs |
| Job | typed unit of work + contract | declarative data, not code |
| Role | who does it (prompt + model + tools + rubric) | Thinker · Generator · Reviewer · Director |
| Placement | where it runs | **policy, not topology** |

`placement is policy` is what makes Venue B cheap to add: the second persona is another
config row consumed by the same machinery, not a second system.

---

## 9. Instruments

| Instrument | Why |
|---|---|
| **`non_follower_reach`** | The **primary** metric. The only number that has ever moved, and the only one that measures discovery at all. |
| Reach split, profile views, saves (per post) | Diagnose *which* post produced discovery |
| Hypothesis ledger | Every Thinker hypothesis pre-registered; evaluated next cycle; auto-revert on failure |
| Render provenance | `base_model` / `seed` / `prompt_hash` / `quality_metrics` on every render |
| **Fix the 64 blank `failure_reason`s** | Cheap win; currently invisible failure |

"Growth in general" is accepted as the goal — but growth cannot be steered without
instruments. Proposal: the goal is **sustained non-follower reach**; followers are the
**lagging outcome**; the Thinker's hypotheses are the **things under test**.

---

## 10. Salvage map

| Promote to core | Keep, reframed | Replace |
|---|---|---|
| Reel rail (`ReelBuilder`, `Instagram::Client#create_reel`, `reel_path`, `ReelArm`) — the diagnosis *and* the fix | `PipelinePromptSafety` → **legality only** (drop moralising) | fused cron tick → **queue + triggers** |
| `SchedulerGate` + `comfyui_harness.sh` → **batch GPU controller** | NSFW gate + vision path (`qwen3-vl:32b` pulled) → **Reviewer rubric** | `StrategyBrain` thermostat → **Thinker** |
| `turbo-one-step-clean` workflow + payload tokenizer | `Growth::Decision` / `Review` ledger → extend to all roles | `PillarPrompt` templates → model-written specs |
| Corpus + `corpus_backup.sh` (the real asset) | Identity anchor / taste tokens | `gemma3:27b` captions → **uncensored local** |
| Instagram publish + `PostSlotPlanner` | `non_follower_reach` → primary instrument | static-first pipeline → **reels-first** |

**Infra ready, nothing to install:** llama.cpp CUDA 12.4 build at
`~/source/activity/llama.cpp/build/bin/llama-server`; uncensored models already pulled
(dolphin3, NemoMix-Unleashed-12B, gemma-3-27b-abliterated, gpt-oss-20b-Derestricted,
JOSIEFIED-Qwen3:30b).

---

## 11. Open items

1. **Verify** Fanvue's current AI-chat/DM automation policy before designing engagement automation.
2. Decide whether **X** becomes a second discovery surface.
3. Default motion rail: **LTX-2.5 AV** vs WAN 2.2 i2v — cost/quality trade-off.
4. Interstitial funnel design (Venue A → Venue B, no direct explicit link).
5. Which uncensored model for the Thinker/Generator — **test empirically**, don't assume.
6. Build scope: restructure in place vs fresh repo.
7. Pre-register the reel hypothesis with a real evaluation window (currently n=1).

---

## 12. Revision v2.1 — founder redirect (2026-10-18)

### 12.1 Gates → controls (the biggest architectural change)

The old design ran every render through a chain of fail-closed gates, and the only
quality gate passed 6–7 on imagery the founder deleted by hand. The founder's rule:
**controls measure and select; they do not veto.** The exception is the legal floor.

This changes the *shape* of the pipeline:

```
OLD:  generate ONE  → gate chain (fail-closed) → caption → publish
NEW:  generate N    → measure all + human-rank  → caption the winners → publish top-k
```

Generation is cheap; **selection is where quality comes from.** A veto gate can only
reject. A control can *rank* — and "nobody is going to follow Sarah for her cooking" is a
ranking statement, not a gate statement. Ranking is also how a control becomes useful
without becoming a blocker.

**The one hard gate: the legal floor** — adult, no minor cues, no real-person likeness,
synthetic mark on every published asset. That is universal platform policy *and* criminal
law, not taste. Everything else becomes a recorded measurement.

| Control | What it is | Wired in as |
|---|---|---|
| **elo-picker** | Glicko pairwise rating (`elo`, `rd`, `comparisons`, keyed by `sha256`) | Human ranking at **selection** time — top-k of a candidate pool. Founder is a target-audience member, so this is ground truth, not a proxy. |
| **peakseek.io** | GA as a service: genome = typed alleles (Float/Integer/Boolean/Option), **one fitness number per candidate**, bred across generations | Parameter search. Genome = {checkpoint, LoRA set, steps, cfg, sampler, denoise, resolution, prompt-variant, seed}; fitness = the elo/rd from a rating session, or a measured quality number. |
| **AuraFace** | Face-recognition embedding (`/mnt/nas-ai-models/models/auraface`, HF cache, precomputed FFHQ embeddings, + an SDXL auraface LoRA) | An **identity-consistency number** per render vs the Sarah reference. A measurement and a GA fitness term — candidate replacement for the current identity lock. |

### 12.2 The experiment database — the spine

Founder: *"a normalized, queryable database … keeping input, ratings, quality
assessments, engagement numbers in one place … an important base to have as an
experiment."* Agreed — this is the project's core asset, ahead of any model.

Design rules:
- **Content-addressed on `sha256`.** The hash is the join key across every table *and*
  across tools: elo-picker already keys images by `sha256`, peakseek needs one id per
  candidate, engagement attaches to a published asset.
- **Normalized, not JSON blobs** — so parameter values, assessments and engagement can be
  grouped, filtered and joined.
- **Provenance on every asset** (existing red line).

| Table | Holds |
|---|---|
| `assets` | `sha256` (PK), path, kind (image/video), dims, duration, bytes |
| `renders` | asset_sha256, workflow + pipeline version, checkpoint, loras, prompt, negative, seed, sampler, steps, cfg, denoise, resolution |
| `assessments` | render, assessor (model + version), metric, value — auraface identity, nsfw score, realism, aesthetic, sharpness, cover-frame risk |
| `ratings` | render, rater, elo, rd, wins/losses/draws (mirrors elo-picker) |
| `comparisons` | left/right render, outcome (mirrors elo-picker) |
| `posts` | published asset, format, cover frame, caption, hashtags, posted_at, platform |
| `post_metrics` | post, follower_reach, **non_follower_reach**, reach_total, profile_views, saves, likes, comments, follows, measured_at |
| `experiments` | hypothesis, pre-registered prediction, genome/params, arm, verdict, decided_at |
| `decisions` | audit ledger (extends existing `growth_decisions`) |

**The critical join is `assets.sha256` → everything.** That is what makes one query
answer the actual research question: *which checkpoint/LoRA/sampler combination produced
the images that earned the most non-follower reach?*

**Open integration decision:** join to elo-picker on `sha256` as an external control, or
absorb its schema into the experiment DB. Do not build a second rating system.

### 12.3 Red-line correction (founder, 2026-10-18) — the previous entry was wrong

**Withdrawn.** The previous revision of this section asked the founder to confirm
reversing `THESIS.md`'s *"never re-enable the unsafe base (Pornmaster graph)"*. That was
miscast: **that red line was authored by a previous agent (DeepSeek), not by the founder
and not by Instagram.** It is agent-invented policy that had been laundered into the
founder's governance document, and it was enforced as though it carried founder authority.

Founder's correction, recorded verbatim in substance:

- The persona **is 18** — that is where the line stands.
- **All photos generated were legal and free of minor cues.** They showed **swimwear, as
  requested** — which is legal and permitted by every platform in scope.

So the constraint was never a founder red line. `CRPv18_PM25`/`PM40` + flux1-dev face and
hand inpaint is the founder's chosen base, with no confirmation required.

**Lesson to carry (the general rule, not just this instance):** an agent may not promote
its own safety preference into a founder red line. A red line in `THESIS.md` must be
founder-authored or founder-ratified, or it does not bind. Audit the rest of `THESIS.md`'s
red lines against that test — this is exactly how a project ends up unable to move.

**What still holds, and why it is a business requirement rather than a moral one:** the
persona's *visual read* must be unambiguously adult. Not because of taste — because
"seems underage" is a **hard, account-terminating rule** on Fanvue and trips Instagram's
borderline classifier. With canon at 18, the visual must not read younger than 18. Keep a
verification step on the flux face pass for that reason alone.

### 12.4 Also revised

- LTX audio is **not** to be used (§7).
- The driving brain is the **local uncensored Qwen3.8-27B** (§6) — no hosted dependency.
- **The founder owns image-generation setup.** The harness consumes what he produces; it
  does not build the image stack. `CRPv18_PM25`/`PM40` were being written to the NAS
  today (2026-10-18 15:29/15:30) — that work is live.

---

## 13. Operating model — founder-in-the-loop via tickets (founder, 2026-10-18)

> *"I am happy to help identify the correct path now, and help guide, but we a) should
> create content now that can be ranked/rated now but also over time. Or we have a proven
> pipeline we are fine with, and when we have time, the system creates a ticket for me
> (founder_needed label or so) and I can go there and do the ranking or whatever is
> required and then the system picks up the results again."*

Two modes: **convergence** (founder guides; small rankable batches; he votes) and
**steady state** (pipeline is good enough; the system runs and only files a ticket when his
judgement is needed).

### 13.1 The ranking loop already exists and is in production — do NOT rebuild it

| Piece | Where | State (2026-10-18) |
|---|---|---|
| elo-picker | `~/source/activity/elo-picker`, unit `elo-picker-puma.service`, `:3010` | live 1w3d; **19 projects, 64,880 images, 26,024 comparisons** |
| GA engine | peakseek.io (token in `~/.hermes/master.env`) | in use |
| harness | `~/source/activity/persona-genome` — `bin/pg draw\|render\|pool\|rank\|report\|status` | last generation 2026-10-16 |
| run data | `~/Documents/obsidian/04 - projects/persona-search/peakseek/gen-NN/` — `img/` is the pool folder, plus `manifest.jsonl`, `workflows/` | gen-16 … gen-21 |
| trust gate | `ComparisonProgress::TRUSTED_RD = 150`; `bin/pg rank` refuses while any rated image is above it | live |
| fitness | `fitness = pop_size − leaderboard_spot`; **never** raw ELO (the roulette needs rank/normalised) | documented |

`gen-21` currently holds 20 images with **0 trusted** — a vote session is open.

**The one missing piece is the ticket handoff.** `bin/pg pool` prints a vote URL and stops;
nothing files a board ticket. Proposed contract:

- **Label `founder_needed`** — distinct from a *ruling* request, which is a decision; this
  is work. Do not overload one label for both.
- **One ticket per pool.** Body: the single axis being ranked, the held-fixed group, the
  pool URL, the expected click budget.
- **Resumption is DATA, not a handshake.** The system reads `GET /projects/{id}.json` and
  proceeds when the pool reports every image trusted. No "done" comment, no label flip —
  `trusted == total` already *is* the completion signal, and `bin/pg rank` already refuses
  below it.
- **The system closes its own ticket** once it consumes the ranking.

### 13.2 The trap that decides how the first batch is built

**A pool is only meaningful if its items vary along the ONE axis being ranked**, and
held-fixed attributes must be held fixed *by pool composition* — split, never merge.
Between-group differences usually exceed between-variant differences, so a merged pool
ranks the uncontrolled attribute and the ordering becomes about the groups.

For Sarah: **5 checkpoints × 12 scenes in one pool would rank *scene*, not checkpoint.**
The first checkpoint read must be one pool per fixed scene (5 items = 10 pairs, a trivial
session), replicated across several scenes — agreement across pools is the robustness
evidence. Density buys power; replication buys trust in the claim.

**Do not rank the existing pool.** `sarah1a3` holds 58,753 images with 33 trusted; it
varies in everything at once and is largely the monotonous content the founder rejected.
Clicks are quadratic (n items → C(n,2) pairs), so ranking it would burn enormous founder
time measuring the wrong thing. Build a small purpose-made batch.

### 13.3 Two instruments, two timescales

"Rankable now **and** over time" is two measurements; conflating them loses both:

- **Now — human taste**: elo-picker pairwise ELO, founder as a target-audience member.
  Session-scale, resolves in one sitting.
- **Over time — audience outcome**: `non_follower_reach` and friends, per published asset,
  only available after publishing.

They join on **sha256** (§12.2). Re-ranking the same assets later is a **new pool** (pairs
are compared once per pool), never a re-run of the old one.

### 13.4 Constraints inherited from the existing loop

- **Do not over-engineer** — the loop is `draw → render → pool → vote → rank → report`. No
  champion special-casing, elitist preserves, immigration, or seed walks.
- One shared seed per generation, rotated each generation.
- Report a strictly-positive floor for a kill; never kill a genotype on an untrusted rating.
- The existing chromosome is **SD1.5 persona-face search** (26 `1.5/person/` LoRA alleles +
  a checkpoint Option over 164 SD1.5 checkpoints). Sarah's content axis is **Pony + Flux**
  and is a different question, so it needs a **sibling** harness with its own chromosome —
  the persona-face chromosome does not transfer.
