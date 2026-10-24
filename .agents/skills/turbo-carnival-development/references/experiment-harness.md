# Controlled render comparison — pre-registered, blinded, paired

How to run a render comparison whose *result* survives scrutiny: a founder preference a later session
can trust, and that cannot be reinterpreted after the fact. Implemented as `scripts/replicate_*.py`,
decoded by `scripts/e2_decode.py`.

## Choosing the axis (do this before writing a pre-registration)

**Pick the axis from a diff of a configuration that already works, not from a mechanism you reasoned out.**
The full treatment — including the corollary that a working config sitting on the *worse* side of an axis you
already measured **exonerates** that axis — is in `references/render-pipeline-operations.md` ("When a sweep
comes back flat or backwards, question the STAGE, not the value").

**Prefer the cheapest axis that can falsify the best available explanation.** A single-leaf value change beats
a structural port when both address the same hypothesis; port when the cheap test comes back flat. Name in
the pre-registration which hypothesis dies if the result is flat.

Comparing two graphs whose node ids differ is its own technique — see
`references/pipeline-graph-inspection.md` §3b.

## Order of operations

1. **Pre-register before the first render** — in `docs/experiment-backlog.md`: the question, the ONE
   varied axis, N, the scene, and the exact decision rule with its thresholds. Put the rule *in code*
   in the decoder so the verdict is computed and printed, not narrated. A rule added after results are
   visible is not a pre-registration.
2. **State the multiplicity honestly.** If an earlier attempt at the same question ended without any
   ranking being observed, the re-run is the **first look**, not a second pass — say so in the
   pre-registration. If a ranking *was* observed, a re-run is a second look and N must account for it.
3. **Freeze the config and record its identity** — workflow sha256 and scene sha256 go into the run's
   blinding key. A comparison whose inputs aren't pinned isn't a comparison.
4. **Assert the frozen config and refuse on drift.** Before rendering, check the live workflow:
   positive contains `1girl, solo`; the negative guards are present; hand denoise >= 0.68; face denoise
   0.66; flux `tg` slot `on:false`. Exit non-zero on any mismatch — a silent drift otherwise reads as
   an arm effect.
5. **Refuse to run on a contaminated scene file.** The pipeline sends the scene file **raw**, so a
   scene file must be pure prompt text — abort if it contains an HTML comment. Notes belong in
   `docs/scene-notes-*.md`.
6. **Wait for the card to be free** (no other sweep running) before the first render, so no arm is
   confounded by a co-resident job.
7. **Pair on seed.** Render both arms at every seed so seed luck cancels *within* a pair. Variation
   across seeds is the replication, not a second variable.
8. **Blind per pair.** Randomise A/B per pair from a fixed blinding seed and write the key to the run
   dir; the key is never shown to the rater. A fixed blinding seed makes the assignment reproducible.
9. **Deliver the sheets from `/tmp`.** WebUI `MEDIA:` tokens are refused outside the allowed roots and
   render output lives on the NAS — stage and probe before emitting (see the media-embed skill).
10. **Decode with the pre-registered rule**, then record the outcome beside the pre-registration.
11. **Before asking for a ranking, prove the axis bit.** Compare the two arms pixel-wise per seed with the
    skill's own generic probe — `scripts/prove_axis_bit.py --a <armA dir> --b <armB dir> --name '<file>.png'`
    — which prints mean/max absolute difference and the share of pixels changed per seed, and exits non-zero
    when the set is vacuous (identical), near-identical, or missing an arm. A near-identical pair set makes
    the ranking measure noise, and handing it over anyway both wastes the founder's attention and lets a
    null result be read as "no preference" when it is really "no difference to see". If the arms are
    identical the test is **VACUOUS**: say so, do not rank it.

    **The bar is not zero — this pipeline is not deterministic.** Two renders of the *identical* config
    differ by up to ~4 levels across ~5% of pixels (measured 2026-10-18: 4/255 on 43,272 px vs 6/255 on
    45,471 px for the guarded pair; dynamic-VRAM load/offload reorders accumulation, and the log's
    `lowvram patches` counts differ run to run). So an axis that moves pixels by **≲ 4–6 levels over ~5%
    of the frame is indistinguishable from noise**: it cannot be ranked, and presenting it manufactures a
    null result out of a real nothing-to-see. The axis must clear the measured floor, not merely differ
    from zero.

## Decision rule and the exact arithmetic

One-sided sign test at N=6, decisive only at unanimity:

| outcome | one-sided p | read |
|---|---|---|
| 6/6 | 0.015625 | rejects the null |
| 5/6 | 0.109375 | no measurable preference — choose on other grounds |
| 4/6 | 0.34375 | no measurable preference |

0.03125 is the **two-sided** value for 6/6 — do not label it one-sided. Mixing conventions inside one
pre-registration is a real error class; state the side every time.

**N is not extended after peeking.** If the rule says "no measurable preference", that is the answer;
a larger N chosen after seeing the first result converts a test into a search.

**Ties must be decided in advance.** If the rule was written with no tie category, a declared tie is
recorded as a non-preference — it does not count toward the numerator, which strictly lowers the
achievable 6/6.

**Size N for the tie rate you actually observe.** Non-preferences consume pairs without contributing a
direction: two ties in six leave a four-pair test, whose unanimity bar is p = 0.0625 — short of the 0.05
the N=6 rule was built around. Before choosing N, look at how often this rater declares a tie on this kind
of pair and buy enough pairs that the *decisive* count still reaches the bar. That is sizing on a nuisance
parameter rather than on the effect size, so it is not peeking — but say which one it is, in the
pre-registration.

**A failed one-sided test does not license the mirror claim.** With H1 = "A preferred" and a result of
1/5, the correct statement is *H1 rejected — nothing established*, **not** "B wins". The mirror
direction at 4/5 is one-sided p = 0.1875, so it misses the same bar the pre-registered direction had to
clear. Reporting the mirror as a win is the post-hoc flip the pre-registration exists to prevent, and it
is most tempting exactly when the pre-registered arm loses.

**Put the tie rule and the mirror rule IN the pre-registration text.** E3 registered the direction and
the thresholds but no tie category, so one declared tie left two defensible readings (1/5 and 1/6) and
*neither* was pre-registered. Having the rule in this file is not enough — it has to be in the
pre-registration the result will be judged against.

**A direction picked after seeing data needs a fresh, separate run.** Reversing the hypothesis once the
first result is visible is legitimate *only* as a new pre-registration on **new** data. The pairs that
generated the hypothesis must never be pooled with the run that confirms it, or the "test" is a search
wearing a pre-registration.

## Choosing the outcome measure

**Match the instrument to the failure mode.** A paired preference test answers "which looks better", but
it is a poor instrument for a *discrete* failure -- at N=6 it reaches significance only at unanimity. When
the acceptance criterion is an **occurrence** (a disconnected limb, a face rendered off its head, a second
person in frame), measure a **defect count** instead: yes/no per render, pooled into a rate. It is more
sensitive, cheaper for the rater (a check rather than a judgement), and it is the thing that actually
blocks a render. Ask for both when both matter, and ask on every pair.

**A secondary outcome must never rescue a primary.** An outcome added after the pre-registration but
*before any ranking* is legitimate -- record it, and state the hierarchy in the pre-registration itself.
The pre-registered primary still governs the verdict; a clean secondary count does not turn a lost primary
into a win. Writing that down is what stops it being revisited once the primary has failed.

**Amend a pre-registration before data, never after.** If you learn something that changes what a *loss
would mean* -- a coupling you had not accounted for -- amend the **interpretation**, not the decision rule;
state that nothing had been observed yet; and record the amendment and its reason beside the original.
Learning it after a ranking is not an amendment, it is a rescue.

**Predict the observable signature, not just a winner.** Before the ranking, name what the mechanism would
*look like* if it were true -- e.g. "limb continuity improves while fine detail degrades" -- and ask the
rater to confirm or deny it explicitly. A confirmed signature upgrades the result from a preference to a
mechanism test, and it gives a loss somewhere to go other than a story about why the hypothesis was still
right.

**When the outcome is a COUNT of gate outcomes, find a positive control before looking for a result.**
Not every experiment needs a ranking: "what fraction of renders clears every gate at this setting" is a
closed-form count, decided by code, needing no rater at all -- and it is the cheaper design whenever the
question is *can we produce this* rather than *which is better*. Two rules make such a run interpretable:

- **Include at least one arm whose outcome is known in advance** (an anchor expected to pass). Without one,
  a sweep where everything fails cannot be distinguished from a broken render path, a value that never
  reached the model, or a harness fault -- "the setting is bad" and "the run is bad" look identical. The
  anchor is a control, not a sample; it is what licenses the negative result.
- **A defect is EXCLUDED from the denominator, and the exclusion is COUNTED AND REPORTED.** A render that
  fails for a reason unrelated to the axis under test (an anatomy break, two people in frame, an empty
  mask) is not evidence about the axis: record it as a defect, drop it, and print how many were dropped. A
  yield quoted over a silently shrunken denominator is the same fault as an incomplete set presented as a
  smaller N.

**Pre-commit the handling of a measurement that is not yet a measurement.** A run can complete without
producing evidence at all -- the eligible set too small, or drawn entirely from before the change under
test. Give the rule a THIRD outcome for that case (the house shape is a verdict of *not a measurement yet:
re-read, do NOT act*), give it precedence over BOTH pass and fail, and fix it before the data exists.
Without it, an unobservable set gets read as a failing one and a live comparison is abandoned on evidence
it could not have produced.

## Pitfalls

- **State a fork in plain language; never present a compressed pair of labels.** Offering the founder
  "(a) ... / (b) ..." in shorthand earns *"I don't understand what I am asked."* Lead with the actual
  question in one sentence ("which question do we spend the GPU on next?"), then give each option as a
  self-contained sentence naming what it costs and what it would settle. A fork the founder cannot
  parse costs the whole round trip.
- **Record the REASON for each pick, not just the side.** Ask for one line per pair. In E3 that turned a
  bare 4–1 into real structure: two of the five decisive pairs were settled by a *lane violation* (a
  nude rear, a nipple) rather than by preference, while the pairs settled on quality went 3/3 the same
  way. Without the reasons the tally conflates "looks better" with "did not breach the lane" — different
  questions, and a rater who flags a defect is answering only the second one.
- **Shared infrastructure goes on BOTH arms — that, not bit-neutrality, is what keeps it out of the
  result.** Adding a node the experiment is not about (a mask guard, a probe, a logger) is safe when it is
  applied to *both* sides: it becomes common-mode, and the leaf diff then proves the arms differ only in
  the axis. Do not try to prove such a node "changes nothing" by rendering it — that cannot be done here,
  because the pipeline is not bit-reproducible. Arguing neutrality from a pixel diff tests for a property
  the pipeline does not have.
- **Enforce "one axis" mechanically, not by intent.** When an arm is a config change, build the arms as two
  *files* and diff every leaf path, refusing unless exactly one differs (`scripts/make_variant.py` does
  this for a workflow). Asserting it is not enough for two reasons: a knob is often **shared** across
  sub-pipelines, so editing "the blend" is editing two nodes; and a single-leaf edit that **feeds a
  downstream stage** (a mask derived from an earlier composite) still moves two stages even though the diff
  says one leaf. Count the leaves *and* check what consumes the node. For a **structural** axis (adding
  nodes, re-wiring) no leaf diff applies — use the scope assertion instead, and for typing CLI values:
  `references/pipeline-safe-clone.md`, "Single-axis variants".
- **Decode the key before interpreting ANY tally — including the rater's raw picks.** Per-pair
  randomisation is unbiased only *on average*; a fixed blinding seed can hand one arm a lopsided share of
  the "A" slots, and then the raw A/B votes point the wrong way. One run put the variant in five of six
  "A" positions, so "B won" was in fact a vote *for the baseline*. Read `blinding-key.json`, map every
  pick to its arm, and only then say which arm won. Never reason about a tally from the letters alone.
- **Abort for cause beats ranking a defective pair.** If one member of a pair is grossly defective the
  pair cannot be read as a preference: abort *before showing any pair*, and record the abort and its
  root cause next to the pre-registration. Never rank it and caveat it afterwards.
- **Position-blinded is not identity-blinded.** The rater may recognise an arm's visual signature.
  State that limitation instead of claiming a blind; pairing on seed is what keeps an identity bias
  neutral.
- **Substring checks must normalise whitespace first.** Scene text wraps across lines so a phrase can
  straddle a newline, and a short check like the bare word `front` collides with other wordings in the
  corpus. Run `re.sub(r'\s+', ' ', text)` before testing, and pick a phrase that occurs in exactly one
  scene.
- **Pin the interpreter and import Pillow at module top.** A background job can resolve a different
  `python3`; a top-level `from PIL import ...` turns a missing dependency into a free failure before
  the first render instead of a crash after the last one.
- **An incomplete render set must FAIL, not shrink.** If any arm render is missing, refuse to build the
  sheets and print that render's manifest status instead. A crash once left 5 pairs against a pre-registered
  N=6 — which reads as "the test ran" when it did not, and the fault class (an empty-mask hard crash) recurs
  per batch. Enforce the refusal in the harness, and never rank the pairs you happen to have.
- **Never edit a config or scene file mid-sweep** — the renderer re-reads it per render, so remaining
  renders silently get different inputs. Kill first, edit, re-register; see
  `references/render-pipeline-operations.md` for the kill/verify procedure.
