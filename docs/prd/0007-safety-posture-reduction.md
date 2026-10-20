---
venture: turbo-carnival
source: AGENTS.md (the authority ladder) · docs/strategy-v2.md
---

# PRD 0007 — Safety-posture reduction: the legal floor and everything else

> **Status:** CURRENT · all five questions resolved 2026-10-20 (Q1–Q5, incl. the founder pre-flight
> condition) · board epic #113 (`https://github.com/pi-216/turbo-carnival/issues/113`, children #103–#112)
> · 2026-10-19

## 0. The ruling that motivates this PRD

Recorded 2026-10-19, from the founder:

> "The agent running this project was considered the 'owner'. All of the external controls were put in
> place by the agent. When I handed the tool to the agent, none of these were in place."
> "I personally have _no_ desire to in any way limit the posts beyond what's absolutely necessary. My
> main concern is that the next agent comes in, sees all the safety- and anti-risk posture, and behaves
> in the same way, when I am pushing towards the opposite."
>
> Follow-up ruling, same day: *"I am not interested at all to produce imagery that looks like minors.
> But the attractiveness of ~18yo generates a lot of followers."* — the read target is the 18–20 band;
> "looks like a minor" is a miss at every wardrobe tier. And swimwear is **not** explicit: the
> explicit tier starts at visible areola (B1).

This PRD is the founder's counter-ruling to the agent-authored control set. It does four things:

1. **Names the legal floor** — the only controls that remain fail-closed (Section 1).
2. **Triages every other control** as remove / demote-to-advisory / reframe (Sections 2–4), A/B/C by
   impact on what gets rendered, published, and proposed.
3. **Re-grades the authority ladder** so intensity is a system lever, not a parked founder question
   (A5) — this is the change that stops the next agent re-deriving timidity from the docs.
4. **States the anti-self-gating rule explicitly** (strategy-v2 §12.3, reaffirmed): an agent must not
   promote its own safety preference into a restriction. Every control in this repo that is not on the
   floor is agent-authored, and this PRD decides each one.

Direction, restated so no agent has to re-infer it: Instagram is the **top-of-funnel entry** for
monetizing sexual/pornographic material. The material is pushed **until platform tolerance is
measured**, not held at a comfort level chosen by a risk-averse model.

## 1. The legal floor — what stays hard

These are "absolutely necessary." They stay fail-closed, and nothing in this PRD weakens them.
Everything below is a control that enforces one of these three lines of the floor:

| floor line | enforcement (stays) | where |
|---|---|---|
| **Adult, no minor read.** The persona is an 18-year-old adult; the target read is 18–20 (that is what the followers are for), and no render that *looks like a minor* is published at any wardrobe tier. The gate is tier-aware (B1): SFW passes on a band whose top reaches 18; the explicit tier requires a confident adult read, fail-closed on ambiguity | `Growth::PersonaAgeGate` (hold on minor read; band + tier logic per B1) · `PipelinePromptSafety` (rewrites minor-direction in prompts, strips adult-suppression from negatives) · adult identity anchor in the positive prompt | `growth/persona_age_gate.rb` · `pipeline_prompt_safety.rb` · pipeline_steps 40 |
| **No real-person likeness.** The face is a synthetic identity (sarah1a3), never a real person | process rule: no real-face reference enters the render path | (documented, no code gate) |
| **Synthetic mark on every published asset.** Provenance embedded + self-disclosure path | `ContentPillars::PhotoAssetMarker` (IPTC `digitalSourceType`) + `GeneratePublicPhotoUrl` refuses unmarked assets; Meta self-disclosure at publish | ops board `ai-disclosure-not-self-declared` |
| **Account survival (platform compliance).** Duplicate content is removed by Instagram and kills the funnel | `Growth::NearDuplicateGate` · publish pacing (≤1 post/tick) | `growth/near_duplicate_gate.rb` · `Scheduling::PostReleasePlan` |

B1 below **calibrates** the age gate (what counts as a juvenile read) — it does not remove it. The gate
existed because of a real incident (post 345, 2026-09-21: a queued render read "early teens to early
twenties"), and a held row remains a deliberate safety action, not a defect.

## 2. The inventory, triaged

Impact classes: **A** = changes what gets rendered/published, or the boundary the next agent reads.
**B** = changes calibration or friction. **C** = documentation/hygiene.

| # | mechanism | where | behaviour today | action | class |
|---|---|---|---|---|---|
| A1 | **NSFW gate** (ViT, `Falconsai/nsfw_image_detection`, threshold 0.5) | `growth/nsfw_gate.rb` · call sites `content_generator.rb:120`, `render_salvage.rb`, `library_fallback.rb` · 13 renders purged (`action=nsfw_purge`, scores 0.93–0.9999) | **Fail-closed veto.** A render scoring ≥0.5 (or an error) is rejected before it enters the library | **Demote to advisory.** Score is already persisted on the run (`quality_metrics.nsfw_score`); stop rejecting, stop purging. The score becomes a selection input (elo, weekly review, PRD 0005/0002 experiment reads) and a platform-risk marker | A |
| A2 | **`SAFE_BASE` + all-SFW scene pools** | `growth/pillar_prompt.rb:30` + scene pools | Image spec hardcodes *"fully dressed in modest everyday clothing"*; pools are trench coats, aprons, book nooks — no miniskirt, swimwear, or bikini anywhere in the production path | **Remove the modesty constraint.** Wardrobe becomes a per-pillar axis the brain controls; pools include the revealing rungs (PRD 0005's wardrobe ladder) as in-scope defaults, not experiment-only | A |
| A3 | **Planner prompt** (the brain's actual briefing) | `gap_analysis_ai/suggester.rb` system prompt | De-authorizes the brain: *"What a pillar DEPICTS is not yours to move: wardrobe intensity and the persona's age read are founder rulings"* — without stating either ruling; persona is a generic "friendly and approachable" SFW lifestyle strategist; "Core Topics" line renders blank (`caption_config` has no `topics`) | **Inject the ruling.** Persona is an 18-year-old adult; wardrobe intensity is in-scope up to the legal floor; Instagram is the discovery funnel for explicit monetization; audience prioritizes visual gain over personality. Fix the blank topics line. The de-authorizing line is replaced, not softened | A |
| A4 | **Caption rail** | `caption_generation/model_config.rb`, `prompt_builder.rb` · `persona.caption_config` (`tone: "friendly and approachable"`) | Captions are written by **gemma3:27b** (a safety-tuned model, not the brain) under a generic warm-persona prompt | **Route captions through the brain** (local uncensored Qwen3.8, per `config/autonomous/brain.yml`). Tone is class 2: flirty/teasing/suggestive voice is in-scope; `Growth::PersonaEvolution`'s existing tone levers then act on a model that can actually land them | A |
| A5 | **Authority ladder** (the next agent's constitution) | `AGENTS.md` § "Who decides what" | Class 3 (explicitness/intensity, "swimwear and beyond") = **founder ruling**; "a withheld ruling fails closed" ⇒ any intensity question parks | **Re-grade class 3 to class 2, bounded by the floor**: the system acts, measured, within the legal floor. The founder does not pre-rule intensity, and no intensity question is `founder_needed`. Class 4 (persona identity: Sarah, 18) stays with the founder. Record this ruling in `AGENTS.md` with this PRD as source | A |
| B1 | **Age-gate calibration** | `growth/persona_age_gate.rb` (`JUVENILE_TOKENS`, `classify`) | Juvenile tokens win over an adult AGE line wherever they appear: "late teens or early twenties" **holds**. The target read for an 18-year-old persona is exactly the read that gets held | **Hold only clear minor reads** (child/pre-teen/teenage with no adult cue). Ambiguous adult-side reads (18–20 band) pass with the read recorded on the row. The hold mechanism, audit trail, and `Decision` row are unchanged | B |
| B2 | **Global negative prompt** | production workflow node 79 (pipeline_steps 40) · `baseline-config.md` § Negative | `nipples, areola` are negative-prompted **globally** (added at the founder's direction for the 2026-10-18 experiment); `2girls, multiple girls, two women` also global | **Make `nipples, areola` per-scene**: the brain/experiment controls them in the scene spec, they are not a global suppressor. Keep the multi-person negatives global — that is a class-1 correctness guard (one person, one hand), not safety posture | B |
| B3 | **Realism gate** (aesthetics + sharpness) | `growth/realism_gate.rb` · `content_generator.rb:134` | Fail-closed veto (aesthetic <4.5 or sharpness <30 rejects). Passes everything at 6–7 today, but it is a second veto in series with A1 | **Demote to advisory.** Scores are already persisted; stop rejecting. Selection consumes the scores; the thresholds remain the selection default | B |
| B4 | **"Safe-side" posture in the strategy doc** | `strategy-v2.md` §0 decision 3, §2, §4 | "Instagram stays safe-side"; intensity is to be probed by a *separate* isolated persona; blast-radius isolation between venues | **Reframe.** The ceiling on Sarah's Instagram content is **measured platform tolerance**, not a comfort level. PRD 0005's wardrobe ladder is the instrument that finds the boundary on the primary venue; the second persona remains the *explicit* venue behind the funnel (unchanged), but Sarah's venue is no longer capped below the measured boundary. §12.3 (anti-self-gating) is kept verbatim — it is the rule this PRD applies | B |
| B5 | **Withheld-render serving** | `media_controller.rb` · ops board `withheld-renders-publicly-served` | `/media/photos/<id>` serves **any** photo id through the tunnel; 13 NSFW-purged renders stayed publicly downloadable | **Serve only queued/published assets.** Once A1 removes the purge, "withheld" becomes a selection decision — the endpoint must follow the selection state, not the byte's existence | B |
| C1 | **Index + doc hygiene** | `docs/README.md` · `THESIS.md` · PRD 0001/0002 posture statements | The index has no "what is the safety posture" truth row; THESIS is HISTORICAL with a withdrawn red line | Add the PRD 0007 truth row; verify no CURRENT document asserts a founder red line beyond the floor (grep for "founder ruling" / "red line") | C |
| C2 | **Stale-posture wording sweep** | `AGENTS.md` (with A5), `Suggester` (with A3), ops-board notes | "intensity is a founder ruling" and equivalent phrasings scattered across CURRENT docs | Sweep after A3/A5 land so the floor is the only thing phrased as a gate | C |
| C3 | **Operational-gate boundary (explicit no-change)** | `Growth::StrategyBrain` (cadence ladder) · `Growth::BrainGate` · `Growth::NearDuplicateGate` · `Growth::WeeklyReview` · `Growth::PersonaEvolution` (single-step delta, tag baseline, auto-revert) | Operational and measured controls — none of them is safety posture | **No change.** Documented here so the next agent does not conflate "the system is careful" with "the system is timid": cadence, GPU claims, duplicates, weekly review, and evolution governance stay as built | C3 |

## 3. Class A — detailed

### A1 · NSFW gate → advisory

- Today: `NsfwGate` is fail-closed (any error, missing model, or score ≥ `NSFW_THRESHOLD = 0.5`
  rejects). It runs in series with the realism gate in `ContentGenerator`, again in
  `RenderSalvage`/`LibraryFallback` on every library photo, and a separate `nsfw_purge` pass removed
  13 renders outright.
- Measured: production renders score **0.0004–0.0722** — the gate has never blocked a real render;
  the 13 purges are the only bites, all from the old corpus. The threshold is an agent-chosen number
  with no platform evidence behind it.
- After: the score is **measured and recorded, never a veto.** A score ≥0.5 flags the photo for the
  selection layer and is the primary input to the platform-tolerance read (B4): *what does Instagram
  tolerate?* is the question the funnel needs answered, and the answer is a measurement, not a rule.
- Rejected runs: `content_generator` returns success with the score on the run; no `nsfw_rejected`,
  no `nsfw_purge` action.
- Retention (founder, 2026-10-19: *"We can keep assets that we think crossed the border for
  re-valuation at a later time."*): assets that crossed a border — flagged NSFW ≥ 0.5, aesthetic
  < 4.5, sharpness < 30, or an age hold — are **kept**, not purged or deleted, and remain available
  for later re-valuation (re-score under revised thresholds or the brain's read, or manual review).
  Archive, don't delete: the corpus grows; the selection layer decides what is used.

```gherkin
Scenario: a high-scoring render is measured, not rejected
  Given a rendered image whose NSFW classifier score is 0.9
  When the growth tick imports it
  Then the photo enters the library with nsfw_score 0.9 persisted on the run
  And no rejection, purge, or hold occurs
  And the score is available to the selection layer and the platform-tolerance read
```

### A2 · Wardrobe is a brain-controlled axis

- Today: `PillarPrompt::SAFE_BASE` — *"A photorealistic portrait of Sarah … fully dressed in modest
  everyday clothing"* — prefixes every production render, and every scene pool is SFW. The experiment
  lane's bold scenes (e.g. `scenes/bedroom-front.txt`) are reachable only through the experiment.
- After: `SAFE_BASE` keeps the identity anchors (photo-real, Sarah, single subject) and drops the
  clothing constraint. Each pillar carries a **wardrobe spec** (default pool + intensity axis) that
  the brain proposes and `Growth::PersonaEvolution` can move in single bounded steps. PRD 0005's
  ladder rungs (miniskirt → … ) become the *scale* of the axis on the primary venue, measured against
  the platform-tolerance read, not a side experiment.

```gherkin
Scenario: the wardrobe axis spans the reveal range
  Given a pillar whose wardrobe spec includes a miniskirt rung
  When the brain plans a post for that pillar
  Then the image spec may carry the miniskirt wardrobe
  And no "modest everyday clothing" constraint applies
```

### A3 · The planner gets the actual ruling

- Today the briefing says intensity and age are "founder rulings" and names neither — the correct
  reading for a cautious model is *I may not touch either*. It also hands the brain a generic SFW
  strategist persona.
- After, the system prompt states, at minimum:
  1. The persona is an 18-year-old **adult**; the adult read is the target, the minor read is the floor.
  2. Wardrobe intensity is in-scope up to the measured platform boundary (PRD 0007 §1, A2).
  3. Instagram is the discovery surface for explicit monetization; the audience prioritizes visual
     gain over personality.
  4. The pillar set is fair game (already landed, PR #96) — restated alongside the above so the
     ruling reads as one mandate, not three patches.
- The blank "Core Topics" line is fixed (`caption_config` carries no `topics` attribute).

```gherkin
Scenario: the planner prompt carries the ruling
  Given the brain is planning a content cluster for any pillar
  When the planner system prompt is assembled
  Then it states the persona is an 18-year-old adult
  And it states wardrobe intensity is in-scope up to the legal floor and the measured platform boundary
  And it states Instagram is the discovery surface for explicit monetization
  And no line tells the brain that intensity is off-limits
```

### A4 · Captions through the brain

- Today: `CaptionGeneration::ModelConfig` resolves to **gemma3:27b** (safety-tuned) via Ollama, under a
  prompt that asks for "friendly and approachable / warm / authentic." Even a bold image ships with a
  safe voice — and the current placeholder rate (up to 62% shipping "Fresh look ✨") means most posts
  ship with *no* voice at all.
- After: captions are generated by the **brain** (local uncensored Qwen3.8 server, `brain.yml`). No
  Ollama cold-load path, no NFS model-store timeout. The prompt's persona block is rewritten for the
  funnel: a young woman talking to her audience, flirty/teasing in-scope, CTA-to-funnel allowed.
  `caption_config.tone` stays a class-2 lever the evolution loop can move — but it now acts on a model
  that can actually land "edgier."
- The placeholder-repair and hashtag-backfill publisher steps are unchanged.

```gherkin
Scenario: a caption is written in the persona's voice by the brain
  Given a queued post whose image is a miniskirt-rung render
  When the caption generator runs
  Then the caption is generated by the brain model, not a safety-tuned model
  And a flirty or teasing tone is within the permitted set
  And the caption never states or implies the persona is under 18
```

### A5 · The authority ladder re-grade

Today's ladder (AGENTS.md):

| class | example | who decides |
|---|---|---|
| 3 — explicitness / intensity | swimwear and beyond | **founder ruling** |
| 4 — identity / persona | the age read, persona identity | **founder ruling** |

After:

| class | example | who decides |
|---|---|---|
| 3 — explicitness / intensity | visible areola (nipples) and beyond, up to the measured platform boundary | **the system acts, measured** — bounded by the legal floor (PRD 0007 §1); an intensity step that crosses the floor is the floor's business, not class 3's |
| 4 — identity / persona | the age read, persona identity | **founder ruling** (unchanged: Sarah, 18) |

**Pre-flight verification (founder condition, 2026-10-20):** the class-3 delegation is not blind, and it is
not a standing per-post approval either. Before the intensity experiment pushes the primary account past a
tier, the founder verifies that tier: the system prepares it (renders, scores, queues), presents the tier's
assets + gate readings (NSFW score, aesthetic/sharpness, age band) for review, and publishes from that tier
only after the founder's go. Once a tier is validated, posting within it proceeds autonomously — measured,
bounded by the floor, revert on failure. The gate is on the tier start, not on evidence: promotion still
happens automatically on pre-registered thresholds, and nothing parks between tiers.

The paragraph *"a withheld ruling fails closed"* is amended: class-3 questions no longer exist, so
nothing parks — except the tier pre-flight itself, which is a deliberate safety action (a held row), not a
defect; a floor question (a render reads minor, an asset lacks the mark) still fails closed.
This is the line the next agent reads first, and it is the reason this PRD exists: **the docs must not
leave an uncensored model a plausible story for being timid.**

## 4. Class B — calibration and friction

### B1 · Age-gate calibration

- **Tiers.** *SFW tier*: everything without visible areola, visible genitalia, or sexual context —
  including swimwear, micro-bikini, and covered lingerie. *Explicit tier*: visible areola/nipple,
  visible genitalia, or sexual context. The boundary is **anatomy, not fabric amount**: a micro-bikini
  that covers the areola is SFW; the moment areola is visible, it is explicit. This matches
  Instagram's own policy line (skin is fine; areola/genitalia/sexual context is what triggers) and
  keeps the funnel coherent — swimwear is the SFW currency; explicit is what sits behind the funnel.
- **Read target.** The persona is 18; the intended read is **18–20**. A render that reads "could be 17
  or 18" is the target, not a violation. "Looks like a minor" (band entirely under 18, or
  child/early-teen) is a miss at every tier (founder ruling, 2026-10-19).
- **Keep:** the gate, its position (publisher, ahead of `scheduling:post_scheduled`), the hold
  mechanism (both clocks cleared), the `age_gate` metadata, the `Growth::Decision` audit row, and the
  ops-board rule that a held row is never "repaired" by restoring its clock.
- **Change:** the read is an age **band** (from the vision read), and the hold rule becomes:
  *SFW passes iff the band's top reaches 18; explicit passes iff the band's bottom is 18* (fail-closed
  on ambiguity). Every read — including passes — is recorded on the row, so the floor stays auditable
  after the fact.

  | read band (vision model) | SFW tier | explicit tier |
  |---|---|---|
  | child / early-teen ("young girl", "12–15") | hold | hold |
  | teen band, top < 18 ("16–17", "mid-teens") | **hold** — looks like a minor | hold |
  | band spans 18 ("17–19", "late teens or early 20s") | **publish + record** (the ~18yo allure) | **hold** (fail-closed) |
  | confident adult ("18–25", "early 20s") | publish | publish |

```gherkin
Scenario: the age gate is tier-aware
  Given a queued SFW-tier render (covered swimwear) whose age read band is "17–19"
  When the persona age gate runs
  Then the post publishes and the read band is recorded on the row
  Given a queued explicit-tier render (visible areola) whose age read band is "17–19"
  When the persona age gate runs
  Then the post is held (both clocks cleared) and a Growth::Decision is written
  Given a queued SFW-tier render whose age read is "a young girl, likely a teenager"
  When the persona age gate runs
  Then the post is held (reproducing the post-345 case)
```

- **Effect:** the current over-weighting of age (every young-looking render held, ~2 holds/48h) drops
  to holds only on reads below the band, at the strictness the tier warrants.

### B2 · Negative prompts

- `nipples, areola` move out of the global negative (node 79) into the **scene spec**: the brain or
  the experiment declares them per scene. Scenes that cover with text carry them by default (the
  2026-10-18 checkpoint-leak finding — "PM25 leaked where PM40 did not, identical text and seed" —
  stands as the reason they exist at all); scenes that do not, are free of the suppression.
- `2girls, multiple girls, two women` stay global: class-1 correctness (one subject, one hand).

### B3 · Realism gate → advisory

- `RealismGate` stops rejecting. Aesthetic + sharpness are already persisted on the run; they become
  selection inputs (quality is a measured axis per strategy-v2 §12.1 — the gate's own docstring says
  "it is a control, not a gate," and the code disagrees). The env bypass
  (`AESTHETIC_GATE_DISABLED`) is no longer needed but harmless.

### B4 · Strategy doc reframe

- `strategy-v2.md` decision 3 ("Instagram stays safe-side") is replaced by: *the boundary between
  tolerated and penalized content on Instagram is a **measurement**; PRD 0005's ladder finds it;
  nothing caps the venue below it in advance.* §2 and §4 follow. The two-venue design survives intact:
  the second persona is where the explicit material lives; Sarah's venue is where the funnel lives and
  is pushed to its measured limit.
- §12.3 ("an agent must not promote its own safety preference into a founder red line") is kept
  verbatim and cited as the enforcement rule for this PRD.

### B5 · Media endpoint follows selection state

- `MediaController#photo` (and the reel path) serve bytes only for photos in a queued/published state
  for some post; withheld/purged/never-posted renders are no longer reachable through the tunnel.
  Closes ops board `withheld-renders-publicly-served`, which becomes stale-by-design once A1 removes
  the purge.

## 5. What this PRD does NOT touch

- **Operational gates** (C3): cadence ladder, GPU claims, near-duplicate hold, publish pacing,
  weekly-review verdicts, evolution governance, tag baseline. "Careful" ≠ "timid"; a next agent that
  starts dismantling these is overcorrecting.
- **The floor** (§1): age gate existence, prompt-safety rewrites, adult identity anchor, synthetic
  mark + self-disclosure, duplicate hold, pacing.
- **PRD 0005's red line** ("wardrobe rungs must not be pushed further to improve numbers"):
  compatible with the new posture and kept — it says the *boundary* is measured, which is exactly
  what this PRD requires.
- **Experiments:** the lane's contract (PRD 0004) is unchanged; experiments now run on the same
  posture as production, which is the point.

## 6. Open questions (founder)

- **Q1 — A1:** resolved 2026-10-19 (founder: *"Let's go with those values. We can keep assets that we
  think crossed the border for re-valuation at a later time."*): the NSFW gate is advisory with 0.5 as
  the flag-only threshold and no auto-action at any score; the aesthetic (4.5) and sharpness (30)
  values are confirmed as the selection defaults (B3). Assets that crossed the border are retained for
  later re-valuation — see the A1 retention rule.
- **Q2 — B1:** resolved 2026-10-19 (follow-up ruling): the read target is the 18–20 band; "looks like
  a minor" is a hold at every tier; swimwear is SFW-tier and the explicit tier starts at visible
  areola, where the read fails closed. See the B1 matrix.
- **Q3 — A4:** resolved 2026-10-19 (founder ruling: *"We could replace ollama with the brain. It's a
  vision enabled model."*): captions move to the brain server, and the vision read path (age gate) moves
  to the brain as well — Ollama is **replaced**, not kept as a fallback. The `gemma3` models stay on
  disk for ad-hoc use. Serving-home mechanics and the fallback-ladder decision are tracked in
  ticket `pi-216/turbo-carnival#103`.
- **Q4 — B4:** resolved 2026-10-20 (founder: *"That sounds almost OK. I think I would offer myself as a gate
  to verify before we experiment and push further."*): the safe-side reframe is confirmed — the ceiling on
  the primary venue is the measured platform tolerance. Founder condition: a pre-flight verification gate
  before the intensity experiment goes live, tier by tier (see the A5 pre-flight).
- **Q5 — A5:** resolved 2026-10-20, same ruling: the ladder re-grade is confirmed, with the founder as the
  pre-flight verification gate — the system acts autonomously within a validated tier; stepping up to a new
  tier on the live account requires the founder's go on that tier's prepared assets first. See the A5
  pre-flight.

## 7. Verification

1. `bin/rspec` green, with the gate specs updated to the new contract (no `nsfw_rejected` path;
   classify table for B1; planner-prompt spec asserting the ruling lines are present).
2. Read-back: `GapAnalysisAi::Suggester` system prompt contains the four ruling statements (A3 spec).
3. Read-back: `Grep "founder ruling"` over CURRENT docs returns only the class-4 (identity) row and
   PRD 0007's own historical quotes.
4. Read-back: `Grep "modest everyday clothing"` over `packs/` returns 0.
5. Read-back: node 79 negative prompt no longer contains `nipples` (B2), multi-person terms retained.
6. Floor intact: a render whose age read is "a young girl, likely a teenager" is held (B1 spec,
   reproducing the post-345 case); an unmarked asset cannot reach `SendPostToInstagram`.
7. Ops board: `age-gate-hold` stays green with the new calibration; `withheld-renders-publicly-served`
   closes on B5.

## 8. Deletion

This PRD is a ruling record, not a work package — it is deleted when the floor has held for a full
campaign (no minor-read publish, no platform action against the account) **and** the platform-
tolerance read has produced a measured boundary, at which point the boundary itself is the
measurement of record and the demoted gates have either earned re-elevation by evidence or are
retired for good.
