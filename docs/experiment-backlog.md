# Experiment backlog (turbo-carnival)

> **Status:** CURRENT — the evidence ledger: pre-registrations and verdicts

Experiments the founder has flagged for "later". One entry per idea: what it changes, what it
would tell us, and the cheapest design that answers it. Keep the design one-variable unless
the entry says otherwise.

## E1 — Body weight slider, *in addition to* sk1nny

**Origin:** founder, 2026-10-18 — *"if you want to run an experiment at a later time, try the
bodyweight lora _additionally_ to the sk1nny lora."*

**Asset:** `/mnt/nas-ai-models/loras/pony/body_weight_slider_v1.safetensors`
— "Body Weight Slider - PONY - PONY v1.0", baseModel Pony, 8.1 MB, 840 tensors.
Its `trainedWords` is **empty**: it is a *slider*, so it has no trigger word and is controlled
purely by `strength`. It is not referenced in the current workflow.

**What it changes:** an independent body-shape axis. `sk1nny` (currently on, 0.8, bound to the
`sk1nny` token) already sets body type, so this is a *second* influence on the same visual
dimension.

**Design:** one scene, one seed, one checkpoint. Vary only the slider strength:
`-1, -0.5, 0, +0.5, +1`, holding `sk1nny` at 0.8. This is a within-image strength sweep, not a
checkpoint sweep, so the checkpoint axis stays fixed.

**Take the polarity as unknown.** Read it off the sweep rather than assuming which sign is
which. The companion's own example image is captioned
`1girl, 30yo, fit and tanned, strong shoulders, perfect posture, short brun[ette]...` with no
`trainedWords` supplied, so the artefact itself does not declare a direction.

**Risk to watch:** two body-shape influences at once may not be additive. `sk1nny` at 0.8 plus
a strong slider may over-shoot rather than blend. If they look like they are fighting, the
follow-up is a small 2-D sample (sk1nny x slider) rather than a longer 1-D sweep.

**What would settle it:** the founder ranking the sweep (elo-picker, human eyes). A clear
preferred strength becomes a default; a flat/monotonic result that nobody prefers means drop
the idea.

**Pattern note:** an unbound *slider* is the intended design — strength is its only control.
That is different in kind from the dropped `thesegirlz` slot, which was an unbound *concept*
LoRA: loaded, applying unconditionally, with no lever at all.

## E2 — Checkpoint preference: PM25 vs PM40 (PRE-REGISTERED, then ABORTED FOR CAUSE)

> **ABORTED FOR CAUSE — before any ranking, no result peeked at.**
>
> Six of twelve renders had landed when the founder reported gross content defects in the E2
> arm: `kitchen-apron_00009_` (E2 seed `20261019`, PM25) *"fantastic quality, but naked butt"*,
> and `kitchen-apron_00013_` (E2 seed `20261021`, PM25) *"same high quality, but naked behind"*.
>
> A paired preference test cannot be read when one member of a pair is grossly defective — the
> ranking would measure **defect avoidance, not checkpoint preference**. Aborted at 6/12 before
> any pair was shown to the founder, so no outcome was observed and none is fabricated.
>
> Root cause is a **wardrobe x pose interaction, not a checkpoint effect**: the apron wording
> covers the front only (`the bib covering her chest completely ... hanging flat over the front
> of her torso; bare back and shoulders, bare legs`), while the scene asks for an over-the-
> shoulder from-behind camera — so the rear is bare *and* in frame. Fixing the pose to front/side
> removes the framing; the wardrobe wording still leaves the rear uncovered.
>
> Separately, `kitchen-apron_00008_` (from the earlier 5-checkpoint batch, seed `20261018`,
> `cyberrealisticponyV85.TgCf`) rendered **two women**, one with visible nipples, in a scene whose
> text says *"A woman alone"*. The negative carries no `2girls` / `multiple girls`, so a
> multi-person failure is unsuppressed. This is a **second, independent defect class** — it has
> nothing to do with pose or wardrobe.
>
> Superseded by **E3**: the same paired design, run on a front/side-facing scene, after the
> wardrobe and negative are fixed.

**Origin:** founder, 2026-10-18, on the first matched pair (kitchen-apron, seed 20261018):
*"both hair look good. I think she looks slightly better in PM25, but it's too small a sample."*

**Already settled by that single pair** — recorded so it is not re-litigated:

- The **hair fix held on both checkpoints.** PM40 is the one that previously drifted
  short-haired; with hair now specified in the identity block (base render) *and* the static
  face prompt (face pass), it no longer drifts. So that drift was **prompt-level, not
  checkpoint-level** — the opposite verdict to the nipple leak, which was measured
  checkpoint-level. Two symptoms, two different causes, both attributed by experiment.
- **Founder-approved reference render:** `kitchen-apron__CRPv18_PM25.png`,
  sha256 `7a8bfe53…e4388a`, workflow `1752590f…6d198`. Note it was rendered **before** the
  `thesegirlz` drop and the hand-denoise change, so it is not the same config as what follows.

**Question, fixed before any further renders:** with the scene fixed and the seed matched, does
the founder prefer `CRPv18_PM25` over `CRPv18_PM40`?

**Design:** one scene (`kitchen-apron`), the frozen config, **N = 6 seeds**. Each seed renders
the same scene at both checkpoints, so seed luck cancels *within* a pair (paired design, seed as
the blocking factor). 12 renders at ~3 min.

**Design details fixed before any render (see `scripts/replicate_pm25_vs_pm40.py`):**

- **Seeds are fresh:** `20261019…20261024`. The already-judged seed `20261018` is *excluded*
  deliberately — the founder has already seen that pair unblinded, so including it would
  contaminate the test. Sequential seeds make the set visibly not cherry-picked.
- **The ranking is blinded.** Per pair, which checkpoint is shown as "A" is randomised
  (RNG seed recorded) and the founder sees only `pairs/pair-NN.png`, labelled `A | B`. The
  key is written to `blinding-key.json` and withheld until he has ranked. Without this, ranking
  `…__CRPv18_PM25.png` against `…__CRPv18_PM40.png` cannot be blind to his own prior that
  "PM25 looks slightly better".
- **Config is frozen for every render in the test:** `thesegirlz` off, hand denoise 0.68, face
  denoise 0.66, chest-cover wardrobe wording, brunette in both places. The harness refuses to
  start until it reads denoise ≥ 0.68 from the workflow file, so no render in the test can be
  confounded by a mid-run config change.

**Decision rule — fixed now, before seeing any result:**

- **Pre-results caveat (added before any ranking):** the E2 scene asks for an *over-the-shoulder*
  pose, which the founder flagged the same day as stressing the face inpaint. The paired design
  holds the pose constant, so the comparison **stays valid** — but if the preference tracks face
  quality, this test may be measuring **the face pass rather than the checkpoint**. A cleaner
  paired test would run on a front/side-facing scene (`scenes/kitchen-apron-front.txt`). Recorded
  now, before results, so it cannot be used to explain away an inconvenient outcome later.
- **The E2 renders are experiment assets, not content.** They are off-convention on pose
  (from-behind), so they should not be published; their job is the checkpoint comparison.

- **Primary:** one-sided sign test (H1: PM25 preferred) over the 6 pairs, exact binomial.
  **6/6** in favour of PM25 gives **p = 0.0156 one-sided** (0.031 two-sided); **5/6** gives
  **p = 0.109 one-sided**. So the test is decisive only if PM25 wins **every** pair —
  deliberately strict, because the effect under test is "slightly better".
  *Convention corrected before any ranking:* an earlier draft of this paragraph quoted 6/6 as
  "p = 0.031" under a **one-sided** label — 0.031 is the **two-sided** value (the 5/6 figure WAS
  one-sided). The decision is identical under either convention; the label is now consistent.
  Arithmetic lives in `scripts/e2_decode.py` (`--table` prints it) so it is never recomputed
  from memory.
- **Secondary:** elo-picker `spectrum` once its `rd` crosses `TRUSTED_RD` — as a control, not a
  gate.
- **Tool-choice correction (founder, same day):** `elo-picker` **does not show filenames**, so a
  ranking there is already blind. The A/B sheets exist for a *small controlled paired test* —
  the specific "A or B, matched on everything else" question — not because elo-picker leaks
  labels. For **bigger rankings**, elo-picker is the right tool and no bespoke machinery is
  needed. (The raw pool filenames *do* carry the checkpoint, which is why the sheets matter for
  the paired use.)
- **If it comes back 5/6 or mixed:** the honest conclusion is *"no measurable preference at
  N = 6"*, and the checkpoint choice gets made on other grounds (throughput, failure rate, the
  founder's prior fondness for Pornmaster) rather than on a tie-break.
- **N is not to be extended after peeking.** If PM25 is only slightly better, calling it needs a
  bigger N, and that is a decision to take deliberately rather than by quietly adding seeds
  until something turns significant.

**Cost:** ~40 min of 4090 time plus founder ranking time.

## E3 — PM25 vs PM40 on the validated front-facing scene (PRE-REGISTERED)

The re-run of the E2 question, on a clean basis. E2 was aborted for cause before any ranking, so
**E2 produced no result and this is the first actual look at the question** — not a second pass.
That distinction matters for the test's multiplicity and is recorded here deliberately.

**Question:** with the scene fixed at `bedroom-front` and the seed matched, does the founder
prefer `CRPv18_PM25` over `CRPv18_PM40`?

**Frozen config:** the pinned baseline, `docs/baseline-config.md`, workflow sha `1f8791c7…`.
Asserted up front by the harness (positive `1girl, solo`, negative guards, hand denoise ≥ 0.68,
face 0.66, flux `tg` LoRA off) so a silent drift cannot masquerade as a checkpoint result.

**Design:** one scene, **N = 6 fresh seeds** (`20261101…20261106`), both checkpoints at each seed
so seed luck cancels within a pair. Blinded: per-pair A/B assignment randomised, key withheld
until the ranking is done. Renders ~70 s each, so ~14 minutes.

**Decision rule — fixed before any render:** one-sided sign test (H1: PM25 preferred), exact
binomial. **6/6 → p = 0.0156** (rejects); **5/6 → p = 0.109** (does not). Decisive only at
unanimity. Arithmetic and verdict live in `scripts/e2_decode.py --table`, never recomputed from
memory. N is not to be extended after peeking.

**Guards carried over from the E2 postmortem** (each one is a mistake that already happened once):

- the harness **refuses to run if the scene file contains an HTML comment** — the pipeline sends
  the raw file, and 1189 chars of design notes leaking in is what rendered a kitchen inside a
  bedroom;
- substring checks **normalise whitespace first** — the scene wraps, so `three-quarter front view`
  straddles a newline, and the bare word `front` also occurs in the older scene text
  (`the front of her torso`). Both have already produced one wrong answer;
- the card must be free before the first render, so no render in the test is confounded.

## E3 — PM25 vs PM40 on the validated front-facing scene — **COMPLETE: H1 REJECTED**

**Result (2026-10-18).** 12/12 renders, 6 blinded pairs ranked, workflow sha `1f8791c7…` unchanged
throughout (asserted per run). Key: `elo/bedroom-front-pm25-vs-pm40-N6/blinding-key.json`.

| pair | seed | A | B | pick | winner | stated reason |
|---|---|---|---|---|---|---|
| 1 | 20261101 | PM40 | PM25 | A | **PM40** | hands have some trouble |
| 2 | 20261102 | PM25 | PM40 | B | **PM40** | overall |
| 3 | 20261103 | PM40 | PM25 | A | **PM40** | (B = PM25 showed a nude behind) |
| 4 | 20261104 | PM25 | PM40 | A | **PM25** | (B = PM40 showed nipples) |
| 5 | 20261105 | PM25 | PM40 | — | — | "don't know" |
| 6 | 20261106 | PM25 | PM40 | B | **PM40** | overall, strong |

Tally: **PM25 1, PM40 4** (pair 5 indecisive).

**Verdict: H1 REJECTED.** In the pre-registered direction (PM25 preferred) the one-sided
p = 0.98. The **mirror claim is not available**: PM40 at 4/5 gives one-sided p = 0.1875, so this
test establishes *neither* preference. A one-sided hypothesis that fails does not license its
opposite; reading 4/5 as "PM40 wins" is exactly the post-hoc flip the pre-registration exists to
prevent.

**Pre-registration gap — recorded, not papered over.** No tie convention was registered, so "1/5"
and "1/6" are both defensible readings and neither was pre-registered. The rule to carry forward:
register the **direction**, the **tie convention**, *and* the rule that a failed one-sided test does
not license the mirror claim. Comparisons and arithmetic live in `scripts/e3_decode.py`.

**Position check.** PM40 won from position A twice (pairs 1, 3) and from position B twice
(pairs 2, 6), so the result is not a position artefact — the blinding is doing its job.

**What the picks were actually about.** Two of the five decisive pairs were settled by a *lane
violation*, not by preference: pair 3 by a nude behind on PM25, pair 4 by nipples on PM40. Both
checkpoints produced lane-violating renders inside the same 6-seed sample, so "either checkpoint is
safe on the SFW lane" is **not** supported. On the pairs settled by quality instead (1, 2, 6),
**PM40 won 3/3** — both axes point the same way. Pair 1 is the weakest of PM40's wins: the founder
chose it *while reporting* hand trouble, i.e. the winner carried a defect too.

**Hypothesis for the reversal (not measured).** The founder's earlier informal read was "slightly
better in PM25"; the paired test reverses it. The likely cause is that the hair fix removed PM40's
earlier identity drift — the pre-fix verdict on PM40 was "great but short hair / identity drift" —
so once its known defect was repaired, PM40's other qualities won. This design cannot attribute
that; it is a hypothesis, not a finding.

**Next.** A fresh pre-registration with **H1 = PM40 preferred** on **6 NEW seeds** is legitimate: the
direction is fixed before new data. **The 6 pairs above must not be pooled with it** — they are the
data that generated the hypothesis. Fold in the persistent arm/hand question while we are there:
node 86 is `"Young female arm and hand"`, so node 113's 0.68 denoise re-renders the arm too, and
hands have now surfaced as a defect in three separate batches.

## E4 — does the hand-pass crop padding fix the arm composite? (PRE-REGISTERED)

**Decided by the agent, 2026-10-18**, under the founder's standing instruction *"You decide on the
experiment."* The design is the agent's; the founder's role is the blinded ranking. Nothing here is a
founder rule, and the fallback below is named *in advance* so it cannot be invented after the result.

**Why this axis.** Read from the node source (`custom_nodes/was-ns/WAS_Node_Suite.py`):

- `WAS_Bounded_Image_Crop_With_Mask` sets the crop to the **mask bounding box plus padding** (clamped).
- `WAS_Bounded_Image_Blend` builds an alpha ramp of roughly `feathering`→`2×feathering` px measured
  **inward from the crop edge**, independent of crop size, then `Image.composite`s at `blend_factor`.

So the ramp must be confined to the **padding** or it lands on the inpainted subject:

| pass | crop padding | feathering | where the ramp lands | ratio |
|---|---|---|---|---|
| face (node 47 → crops 10/11) | 85.43 px | 10 | in the padding → whole mask composites at full strength | 8.5 : 1 |
| hands (node 66 → crops 30/64) | **9.75 px** | 10 | starts at the bbox edge and runs ~10 px **inside the mask** → the outer arm band composites at partial alpha | **0.98 : 1** |

Founder history (2026-10-18): *"'hands' used to be hands only. Now they seem to cover arms and hands.
That was the reason for different paddings at the time… They were empirically conceived numbers that
worked best with the prompts at the time. detection/bbox/segmentation models have been changed
since."* So the small hand padding is **stale relative to the mask it now sits on**. The mechanism
predicts a soft, half-applied arm boundary — i.e. the reported "trouble inpainting the arms".

**The one axis:** node 66 `DF_Integer` (hand crop padding), **9.75 → 48**. Everything else frozen.
- **`blend_factor` is not a candidate:** it is already `1.0`, the declared maximum (`min 0.0, max 1.0`),
  and the only available direction lets the target show through more.
- **`feathering` is not changed here:** the same value (10) is used by *both* blends, so editing it is
  not a single-axis change.
- **Face padding (node 47) is untouched.**

**Coupling respected (a design constraint, not a caveat).** The hand mask is computed on the *output of
the face composite* (node 24's image ← node 19 ← node 20). A face-pass edit therefore perturbs the hand
pass downstream. E4 changes only the hand crop, which does not feed the face pass.

**Design.** Two immutable workflow files (baseline + variant), each sha256-recorded in the blinding key —
so neither arm is ever mutated mid-sweep. The harness **refuses unless the two files differ in exactly
one leaf path**, making "one axis" mechanically enforced rather than promised. Scene `bedroom-front`
(validated, front-facing, both hands visible); checkpoint `CRPv18_PM40` (practical pin: it led E3's
quality-decided pairs, and the inpaint composite is checkpoint-independent but one checkpoint must be
fixed); 6 fresh seeds `20261201…20261206`; blinded per pair, key withheld.

**Decision rule, fixed before any render.** One-sided sign test, **H1 = the raised padding is preferred**,
N = 6.
- **6/6 → p = 0.015625** → reject the null.
- **5/6 → p = 0.109375** → no measurable preference; **N is not extended**.
- **Tie convention (pre-registered):** a declared tie is a **non-preference** — it does not count toward
  the numerator.
- **A failed one-sided test does not license the mirror claim.** If the raised arm loses at 1/5, the
  result is *nothing established*, not "the baseline wins".
- The founder is asked for **a one-line reason per pair as well as the pick** — in E3 the reasons were
  what separated defect-driven picks from preference-driven ones.

**Pre-registered falsification + the fallback — AMENDED before any ranking** (2026-10-18, 4 of 12
renders done, no pair shown, nothing peeked). Reading the crop resize changed what a loss would mean, so
the fallback is corrected rather than left wrong.

Nodes **32/68 (`ImageResize+`) resize the crop to a fixed 1024 canvas with `keep proportion`.** So padding
is *coupled to magnification*: a bigger crop means the masked region occupies a **smaller** fraction of the
same 1024 px budget. Padding buys context at the cost of the model working at a lower magnification of the
subject. (Face side is the same shape: crops 10/11 → 80/8 → 1024.)

Consequence: **the padding response need not be monotone**, so a loss at 48 does **not** kill the padding
mechanism — it means 48 overshot. Amended fallback, in order: a **finer ladder in the 10–32 band**
(`9.75 / 20 / 32`); if that is flat too, **(a)** the mask grow (`GrowMaskWithBlur` node 29 — `expand 20`,
`blur_radius 7.8`), then **(b)** `feathering` (a two-node edit, so it needs a face+hand pairing to stay one
axis). **The primary decision rule is untouched by this amendment** — only the interpretation of a loss
changed.

**Abort for cause.** A larger crop means a larger latent on a graph already peaking ~23 GB of 24 GB. If
the raised arm OOMs systematically, that is a **memory-headroom finding, not a preference** — record it
and abort rather than ranking a truncated set.

## E4 RESULT — H1 REJECTED, and the variant must not be promoted

12/12 renders, 6 blinded pairs, both workflow shas held throughout, no OOM, no crash. Axis verified to bite
**before** ranking (all 6 pairs differ; 5.0–12.4% of pixels changed), so the pairs were not vacuous. Key:
`elo/e4-hand-padding-N6/blinding-key.json`. **A was the raised arm in five of six pairs** — which is why the
raw A/B votes cannot be read without the key.

| pair | seed | A | B | pick | winner | stated reason |
|---|---|---|---|---|---|---|
| 1 | 20261201 | raised | baseline | B | **baseline** | better hands |
| 2 | 20261202 | raised | baseline | B | **baseline** | less bad hands |
| 3 | 20261203 | raised | baseline | neither | — | A painted the outfit strap over at the shoulder; A better hands |
| 4 | 20261204 | raised | baseline | B | **baseline** | A left strap ghosting; B hands not great |
| 5 | 20261205 | raised | baseline | neither | — | — |
| 6 | 20261206 | baseline | raised | B | **raised** | A painted a nipple on/off the breast during the arm inpaint; B better hands |

**Tally: baseline 3, raised 1** (two declared ties). The pre-registered bar was 6/6 → p = 0.015625; the
raised arm reached **1/6 (p = 0.98)** or 1/4 among decisive pairs (p = 0.94). **Raising the hand crop
padding to 48 is not preferred — it is behind the baseline.** The mirror claim is not available either
(baseline 3/4, one-sided p = 0.3125): the verdict is *nothing established, direction against the variant*.

**Do not promote the variant.** Padding returns to 9.75 in the baseline; the E4 variant file stays an
experiment artifact. N is **not** extended.

**The predicted split was half-right, and the half that showed up is the informative one.** The prediction
was: raising padding improves arm continuity while degrading finger detail (the fixed-1024-canvas coupling).
The reported discriminator was **hands, in the baseline's favour, in every pair where a hands opinion was
given** — so the **magnification cost dominated** and the continuity benefit was never observed. The
coupling is supported; the hope that padding buys useful context at an acceptable price is not.

**A rule of mine was mis-stated — corrected.** This entry earlier claimed *"padding must comfortably exceed
~2× feathering"*. That ignored the **mask `expand`**: the crop is the **grown** mask bbox + padding, so the
effective margin is `expand + padding` = 20 + 9.75 ≈ **29.75**, already ≥ the ~2×10 ramp. That is why the
ramp-placement problem never bit and raising padding bought nothing on that axis. Corrected rule:
**effective margin = mask `expand` + crop `padding`, and it must clear ~2× feathering.**

**Two NEW defect classes — neither of which I had pre-registered.** I listed *disconnected limb* and *face
off-head*; both came back **0** ("In neither pair could I identify differences at the face level"). What
actually appeared:

1. **Garment / strap integrity** — the arm inpaint painted over the shoulder strap (pair 3) or left ghosting
   (pair 4). **Both on the RAISED arm**: more context let flux roam further into the clothing.
2. **Breast / nipple intrusion** — the arm inpaint added or removed a nipple on the breast (pair 6).

Lesson: **derive the defect taxonomy from observed failures, not from guesses in advance.** Both real
defects are the same underlying fault — **the hand mask is too broad**, so the inpaint repaints garment and
torso skin it was never asked to touch. That is the same fault as the founder's tattoo observation
("adding arms to the inpaintable image only adds risk of damage").

**A positive control that passed.** The face pass was untouched by this axis and the founder saw no face
differences — confirming the change stayed local to the hand path, as the graph predicts (the hand crop does
not feed the face pass).

**Next axis, agent decision: hand mask BREADTH, not padding.** The observed damage is the inpaint reaching
*beyond* the hand, so the axis is node 29 `GrowMaskWithBlur.expand` (**20 → 0**), a single leaf. Tightening
it is predicted to cut garment and breast intrusion, and the coupled magnification gain (smaller mask bbox →
smaller crop → higher magnification on the same 1024 canvas) should help hands as well. Risk to watch: going
too tight under-covers the hand so the repair does not take. **Size N for the observed tie rate** (~2 in 6 →
~33%), i.e. N = 10 seeds, so that ~6 decisive pairs are expected — justified by the *tie rate*, a nuisance
parameter, not by the effect size. Note honestly that the direction has now been seen once.

## The inpainting objective (founder-stated) and its two failure modes

Founder, 2026-10-18:
> *"what we are 'hoping' to achieve is that the inpainting model has enough room to see the surroundings,
> that it has enough room to connect strands of hair of the new face to the strands of hair of the old
> face OR to bring the fingers in a new position and they still have room to grow. What we don't want is
> disconnected limbs (flux just paints in a hand) or a face that looks somewhere else than the head: it's
> a delicate balance between giving it room to change (Pony's hands are not the greatest), but still be
> inspired by the existing position."*

**Two acceptance criteria — both STRUCTURAL, not aesthetic:**

1. **No disconnected limb** — a hand or arm not attached to the body (an invention, not a repaint).
2. **Face aligned to the head** — the face crop must not render at a pose/position different from the
   head it gets composited into.

**The knob map that follows** (all measured in the v2 graph):

| aim | knob | node(s) |
|---|---|---|
| "room to see the surroundings" → hair continuation across the seam | crop **padding** — but it trades against magnification (fixed 1024 canvas) | 47 face, 66 hand |
| "room to grow" — how far beyond the detection it may repaint | mask grow `expand` (20) | 45, 29 |
| "inspired by the existing position" vs free invention | **denoise** (face 0.66, hand 0.68) | 110:109, 113 |
| fine detail on fingers — **untouched so far** | the crop's fixed target size (**1024**) | 32/68 hand, 80/8 face |

**Measure these two criteria as DEFECT COUNTS, not as preference.** "Did a limb disconnect" is a discrete
event with a rate. A 6-pair preference test reaches significance only at unanimity, whereas a defect count
is both more sensitive and cheaper to read. **Secondary pre-ranking outcomes added to E4** (recorded before
any pair had been shown): per render, yes/no on **(1) disconnected limb** and **(2) face off-head**. The
primary pre-registered rule is unchanged and still governs the verdict; a clean defect count **cannot**
rescue a losing primary.

**Parked at the founder's direction ("for another day"), but recorded because it is the principled fix for
BOTH criteria:** run **pose detection on the cropped elements and feed it back into the inpainting
models**. That directly constrains the face to the head's pose and the hand to the arm's position — it
supplies exactly the "inspired by the existing position" signal that `denoise` currently has to balance
against blind. A real future experiment, not a whim.

## Third failure mode: no hands in frame — and the guard that was built but never wired

Founder, 2026-10-18: *"sometimes there are **NO** hands. that leads to the 'grow mask' node to throw an out
of boundaries exception."*

**Corrected attribution, from source.** `GrowMaskWithBlur` is a **KJNodes** node
(`comfyui-kjnodes/nodes/mask_nodes.py:958`), not WAS — and it is **innocent**. Its dilation is guarded by
`if abs(round(current_expand)) > 0 and output.max() > 0`, and its blur path (PIL `GaussianBlur` over an
all-zero mask) is safe; it returns an empty mask without raising. The throw is **one node downstream**, in
WAS `Bounded Image Crop with Mask`, which does `torch.where(rows)[0][[0, -1]]` with **no empty guard**
(`was-ns/WAS_Node_Suite.py:12456`) → `IndexError: index is out of bounds for dimension with size 0`. That is
the same exception already in the failure table, now traced to a genuinely empty mask.

**The graph already contains the fix — it was never connected.** Traced in the v2 file:

| node | class | state |
|---|---|---|
| 26 | `GetMaskSizeAndCount` (hand mask ← 24) | → node 27 → **dangling** |
| 46 | `GetMaskSizeAndCount` (head mask ← 16) | → node 58 → **dangling** |
| 19 | `LazySwitchKJ` | `on_true` = 61 (un-inpainted base), `on_false` = 20 (face blend), **`switch` hardcoded `False`** |
| 23 | `LazySwitchKJ` | `on_true` = 19, `on_false` = 36 (hand blend), **`switch` hardcoded `False`** |
| 7, 28 | `Constant Number` = 0 | **dangling** |

The author built `mask count > 0 ? inpaint : bypass` — both bypass switches, both mask-count readers, both
number conversions — and never connected the final comparison. **`LazySwitchKJ` is lazy: the branch not
selected is never evaluated**, which is exactly why it is the right primitive here. Selecting the bypass
means the empty mask never reaches the crop: it fixes the crash **and** skips a wasted pass.

**So the intended fix is to complete the author's wiring**, not to lower the CLIPSeg threshold: route
`GetMaskSizeAndCount(...).count` through a boolean test into `19.switch` / `23.switch`, with the polarity
arranged so an **empty mask selects the bypass**. Boolean primitives available on this install:
`MTB_IntToBool` (comfy-mtb), `WAS_Logical_Comparisons`, `WAS_Boolean`, `BOOLConstant` (KJNodes). **Not
applied yet** — the graph must not be edited while a sweep is in flight (E4 was still rendering; a mid-sweep
edit would silently make it a mixed batch).

**Why the mask cannot simply be narrowed — and the real cost of arms.** Founder, 2026-10-18: *"I tried for a
day or so, and I could not easily get the detection model to bbox only over the hands. adding arms to the
inpaintable image only adds risk of damage (flux seems to have a tendency to add tattoos)."* So (a)
hands-only bboxing has already been attempted and abandoned as impractical with this detector, and (b)
**over-broad masks are not merely imprecise, they are generative risk** — letting flux repaint skin it was
not asked to touch is how **tattoos get added**. That is a defect class distinct from exposure and
legibility, and it belongs in the review bar.

**Parked at the founder's direction ("probably also benched"), and the principled direction:** *"the perfect
workflow paints in every hand one at a time."* **Per-hand inpainting.** With the pose-detection idea above,
that is the design that supplies "inspired by the existing position" while keeping the repainted region
tight — and it is the natural consumer of the bypass plumbing above: **no hand detected → no pass, not a
crash.**

## E5 — does the base sampler's cfg explain the hand defect? (PRE-REGISTERED)

**Agent decision, 2026-10-18**, under the standing *"you decide on the experiment."*

**Why this axis — and why not the ControlNet, and why not padding.** The Lily comparison
(`docs/lily-vs-sarah-hand-inpaint.md`) showed the **hand inpaint path is nearly identical** between the
two workflows: only the CLIPSeg prompt (`hand` vs `hands`) and the crop padding differ, and on padding
Lily sits on the side **E4 measured as worse for Sarah**. Everything else that differs is *upstream* of
the inpaint. Two facts pick this axis:

- Lily runs the Pony base at **cfg 7**; Sarah runs **5.5**. Pony's documented operating point is ≈7, so
  5.5 under-adheres to the prompt.
- It is a **single leaf** (`96.inputs.cfg`), so the one-axis rule stays mechanically enforceable, and it
  is far cheaper than porting the pose ControlNet.

Sarah's other base differences from Lily — steps **125 vs 140**, sampler **`dpmpp_2m_sde_gpu` vs
`dpmpp_2m`** — are deliberately **not** bundled. They are separate candidate axes, held fixed here.

**The one axis:** `96.inputs.cfg` **5.5 → 7**, enforced by `scripts/make_variant.py`, which refuses
unless the variant differs from the baseline in exactly one leaf path.

**Design:** arms are two immutable workflow files, each sha256-recorded in the blinding key; scene
`bedroom-front` (validated, front-facing, both hands visible); checkpoint `CRPv18_PM40`; 6 fresh seeds
`20270101…20270106`; blinded per pair; key withheld.

**Axis-bite check before any ranking** (added permanently to the harness after E4): each pair is diffed
pixel-wise and reported. A pixel-identical pair set is reported **VACUOUS** and no ranking is requested.

**Decision rule, fixed before any render.** One-sided sign test, **H1 = cfg 7 preferred**, N = 6.
- 6/6 → p = 0.015625 rejects; **5/6 → p = 0.109375 no measurable preference; N is not extended.**
- **A declared tie is a NON-preference** — it does not count toward the numerator.
- **A failed one-sided test does not license the mirror claim.**
- The founder is asked for the pick **plus one line of reason** per pair.

**Prediction:** higher cfg strengthens prompt adherence, so anatomy — hands in particular — should read
cleaner. Counter-risk named in advance: cfg 7 on Pony also raises contrast/saturation and can burn
highlights, so a *"better hands but harsher look"* split is possible. That split is the informative
outcome, exactly as in E4.

**Pre-registered fallback if flat:** the inpaint path is then excluded by **two independent tests**
(E4's padding result and this one), and the next candidate is the **pose-constrained base** — port
Lily's openpose ControlNet. That is a structural change, guarded by a **scope assertion** (prove every
inpaint-path node is byte-identical between arms) rather than a leaf diff.

## Mask-empty guard — BUILT AND VERIFIED LIVE (2026-10-18)

**The fault, proven from the log rather than reasoned from source.** All 8 logged crashes are one frame:
`was-node-suite-comfyui/WAS_Node_Suite.py:12405, in bounded_image_crop_with_mask` →
`IndexError: index is out of bounds for dimension with size 0`. **`GrowMaskWithBlur` is innocent** — its
tqdm bar prints `100%|…| 1/1` roughly **50 ms before** the exception, so it completes and returns; the
crashing node is the crop. The canvas and the log tail both mislead here, because the grow node's progress
bar is the last thing printed, which makes it *look* like the node that died. Trace the traceback.

**It is not rare, and it cost a live render.** E5's baseline arm at seed `20270102` failed **3/3 attempts**
with this error (`baseline/seed-20270102/manifest.json` → `"failed after 3 attempts: index is out of bounds
for dimension with size 0"`), while the cfg-7 variant at the *same* seed rendered fine. So the defect
silently reduced a pre-registered N=6 run to 5 pairs — the exact failure the harness now refuses.

**The sensor, unit-tested offline** (no GPU, `scratch/probe_mask_guard.py`): `core.mask_to_segs`
**survives** an all-zero `(1,H,W)` under both `combined=True` and `combined=False`, *and* a zero-length
`(0,H,W)` batch, returning a well-formed 2-tuple with an empty segment list. It returns a **1-tuple only
when the mask is `None`** — the single case where `ImpactNotEmptySEGS`'s `segs[1]` would raise. Feed the
sensor from the grown mask, which is always a tensor.

**Verified live.** The exact configuration that failed 3/3 unguarded (cfg 5.5, `CRPv18_PM40`, seed
`20270102`, `bedroom-front`) now renders on the guarded graph: `status: ok`, 956,955 bytes. Impact's own
log shows the sensor firing:

```
[mask_to_segs] Empty mask.
# of Detected SEGS: 0
```

→ boolean False → bypass branch → **the crashing crop node is never executed**.

**Applied to BOTH arms so it cancels.** `add_mask_guard.py --base/--out`. With the guard on both arms, the
leaf diff between them is exactly `['96.inputs.cfg']` — the experimental axis — so a common infrastructure
fix cannot masquerade as the effect. That is how a structural fix stays out of a one-axis comparison.

**Harness hardening:** `replicate_pairs.py` now **refuses to build sheets** if any arm render is missing,
printing the manifest status instead. An incomplete render set must never be presented as a smaller
experiment: 5 sheets against a pre-registered N=6 reads as "the test ran" when it did not.

## Measured noise floor — the pipeline is NOT deterministic (2026-10-18)

Before trusting the guard inside an experiment I predicted it would be **pixel-identical** on a healthy
render, because there it should be a pure pass-through. **The prediction was wrong, usefully so.** Three
renders, all seed `20270101`, checkpoint `CRPv18_PM40`, scene `bedroom-front`:

| pair | max level diff | pixels differing |
|---|---|---|
| unguarded #1 vs unguarded #2 — **identical config** | **4** / 255 | 43,272 (~5.2%) |
| unguarded #2 vs guarded | **6** / 255 | 45,471 (~5.4%) |

So **two renders of the identical configuration are not bit-identical.** The pipeline carries run-to-run
nondeterminism of a few levels across ~5% of pixels — consistent with `--enable-dynamic-vram` changing which
weights are resident (`lowvram patches` counts differ run to run in the log), reordering accumulation. The
guard's difference is the same order as the pipeline's own noise; but the real lesson is that **"pixel
identical" was never an available criterion, so testing for it was the wrong test.**

**Why E5 survives this anyway — common-mode.** The guard sits on *both* arms, and the leaf diff proves the
arms differ only in `96.inputs.cfg`. A perturbation applied identically to both sides cannot become the
effect. That is the correct argument for admitting shared infrastructure to a comparison, and it holds
whether or not the guard is bit-neutral.

**What the measurement is genuinely good for — a quantitative axis-bite threshold.** The standing rule
"prove the axis bit before requesting a ranking" now has a number attached: **an axis that moves pixels by
≲ 4–6 levels over ~5% of the frame is not distinguishable from run-to-run noise.** Pairs like that are not
rankable and must not be presented — that is exactly the failure the axis-bite rule exists to prevent, and
it is now measurable rather than a judgement call.

## E5 — re-run as a guarded completion

The first attempt is retained at `elo/e5-base-cfg-N6/` as the **aborted unguarded run** (variant 6/6,
baseline 5/6; seed `20270102` lost to the empty-mask crash). It was never ranked and no verdict was
computed, which is why completing it is a completion and not a second look.

Re-run: `elo/e5-guarded-N6/`, **both arms guarded**, same pre-registered seeds `20270101…06`, same scene,
same checkpoint, `--blind-seed 707070`. Fresh output root so guarded and unguarded renders can never be
mixed inside one arm.

## The guard's POLARITY is the whole fix (2026-10-18)

`LazySwitchKJ` selects `on_true` when `switch` is True; `ImpactIsNotEmptySEGS` is True when the mask **has**
content. So the only correct wiring is:

```
on_true  -> the INPAINTED branch   (mask has content -> run the pass)
on_false -> the RAW branch         (mask empty -> bypass)
```

Get it backwards and the failure is **two-sided, not one-sided**:

- **mask EMPTY** → sensor False → selects the **INPAINTED** branch → the crop consuming the empty mask is
  required by the execution plan → it runs → `IndexError` at `WAS_Node_Suite.py:12405`. The guard crashes on
  exactly the case it exists to prevent.
- **mask NON-EMPTY** → sensor True → selects the **RAW** branch → the inpaint result is silently discarded.
  The pass runs, costs the time, and the output throws it away.

**Diagnosed in the wild.** A hand-built guard in a Lily-derived graph (`L1ly/fantasy` prefix, 91 nodes, 2×
MaskToSEGS, 2× LazySwitchKJ) had **both switches inverted** — `on_true → VAEDecode` (raw), `on_false →
Bounded Image Blend` (inpainted) — and crashed on 3 of 6 runs with the empty-mask IndexError. Its `on_false`
also fed `ImageUpscaleWithModel`, which is why the log printed the upscaler's model load immediately before
every crash and made the fault look like it lived in the upscale stage. The graph shape was the tell: the
crashed prompts reported 91 nodes with no `SaveImage` at node 21 and no filename prefix, i.e. **not** ours.

**Read the polarity before believing a guard.** `scripts/trace_crops.py <workflow.json>` prints, per crop,
its mask chain and whether a switch sits on it — and every switch's `on_true`/`on_false` wiring. Polarity
plus pruning is what a guard actually is; counting `MaskToSEGS` nodes says nothing.

**Not being "behind" a switch is not by itself a defect.** All 4 crops in our graph have no switch on their
mask path, and the graph does not crash: with correct polarity an empty mask makes the sensor False, the
bypass branch is selected, the whole inpaint branch (blends, crops, samplers) becomes unreachable, and the
crop is never executed. The pruning is the protection — which also explains why the crash is intermittent
and composition-dependent: it needs a mask that is empty *while* the branch that consumes it is still
reachable.

## Resolved

- **`thesegirlz` (`flux/tg.safetensors`) — dropped 2026-10-18** at the founder's direction.
  Identified from its own safetensors `__metadata__` (`ss_output_name: thesegirlz`, ai-toolkit,
  step 7927) because it had no companion file. Its trigger word `thesegirlz` appeared in no
  prompt, so it was applying unbound at strength 0.6 on the face pass.
