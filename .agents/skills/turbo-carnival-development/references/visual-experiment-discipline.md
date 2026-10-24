# Running a credible image experiment (turbo-carnival)

The founder holds a research standard, not a demo standard. He answers "I think it looks
slightly better" with *"too small a sample"* -- so the correct response to a weak impression is
MORE DATA under a fixed rule, never a stronger claim. Design to that.

## What counts as a defect (the review bar)

The founder separates two kinds of bad, and so must you:

- **Defects** -- exposure and legibility failures he expects FIXED: a visible nipple, an
  uncovered rear, a second person in a scene whose text says "a woman alone", a missing or
  garbled face. These block a post.
- **Imperfections** -- quality shortfalls he explicitly tolerates: a weak face crop on an awkward
  pose is *"not a blocker generally"*. Do not escalate these into defects, and do not let an
  agent's own taste harden into a persona rule.

Getting the two confused erodes trust in both directions -- crying defect over an imperfection,
and waving a defect through.

## Defaults that apply to every experiment here

- **Pre-register before rendering.** Write the question, the design, the exclusions and the
  DECISION RULE into `docs/experiment-backlog.md` before the first render or ranking. A rule
  chosen after seeing results is indistinguishable from motivated reasoning, however honest the
  intent.
- **The founder delegates the experiment DESIGN to the agent.** Standing instruction, 2026-10-18:
  *"You decide on the experiment."* His role is the **blinded ranking**, not design review. So decide,
  pre-register decisively, **name the fallback axis in advance** (so it cannot be invented after the
  result), and ask him for the pick **plus a one-line reason per pair** — the reasons are what
  separate defect-driven picks from preference-driven ones.
- **One axis per test.** Hold scene, seed, LoRA stack and config fixed; vary only the thing under
  test. A shared seed across arms is deliberate -- seed luck must not confound the comparison.
- **Controls, never gates** (founder-locked): `elo-picker`, AuraFace and peakseek are instruments
  for measuring and steering. Nothing here vetoes a render on taste; the only hard floor is legal.
- **State a tool's limits honestly.** `elo-picker` hides filenames, so a ranking there is already
  blind. Do not invent a blinding scheme for a question it already answers, and do not build
  ranking machinery that duplicates it.

## Blinded paired test (the small controlled comparison)

Use when the question is "A or B, matched on everything else".

1. Pick N pairs (N = 6 gives a workable exact test). Each pair is ONE seed rendered at both arms,
   so seed luck cancels *within* the pair -- the seed is the blocking factor.
2. **Use fresh seeds** and exclude any seed the founder has already judged unblinded. A
   previously seen pair is not blind however it is re-presented.
3. **Randomise which arm is "A" per pair** from a recorded RNG seed, and keep the key back
   (`blinding-key.json`) until the ranking is done. Compositing each pair into one side-by-side
   sheet labelled only `A | B` holds the founder's workload to one comparison per pair.
4. **Freeze the config for the whole test** and make the harness REFUSE to start until it reads
   the frozen value from the workflow file -- otherwise a mid-run edit silently turns the test
   into a mixed batch.
5. **Put the decision rule in code, not in prose.** A repo `scripts/*.py` that (a) prints the
   rule table up front so thresholds are checkable without knowing any outcome, (b) refuses a
   verdict on incomplete data, and (c) prints the pre-registered conclusion itself. That is what
   stops an inconvenient 5/6 being narrated into a pass in the summary.
6. **Pick one convention and label it** -- one-sided vs two-sided. A rule quoting a two-sided p
   under a one-sided label is ammunition later; fix it before results and note the fix.

## Abort for cause

If the data turns out **grossly defective** by the bar above -- an uncovered rear, a second
person, an artefact that dominates the frame -- the test is not measuring what it claims to.
Abort it and write the abort and its reason into the backlog BEFORE any ranking: a pairing where
one member is grossly defective measures *defect avoidance*, not preference.

Aborting over a defect found before ranking is not peeking -- no outcome has been observed. Say
that explicitly, so the abort cannot later be mistaken for a concealed result.

## Gate calibration over an existing image set (rescoring)

When a ticket changes a gate's logic or question and the effect must be measured over an existing
image set, re-score -- do not re-render. Probe the set once with the new question, then score all
reads through the gate's OWN pure decision path (parse -> verdict -> hold?), never a by-hand
reimplementation.

- **Byte-compare the probe's question against the gate source before trusting the run.** Extract
  the QUESTION literal from the gate file and byte-compare it with the probe script. Wording is
  part of the measurement: a reworded question over the same set moved the measured hold rate from
  49.7% to 29.0% (juvenile reads 47% vs 26%). A completed probe run with a different wording is a
  sensitivity variant, not the calibration.
- **Derive the old baseline from the old reads, not from memory.** Recover the pre-change gate
  from git history (`git show <pre-change-commit>:<path>`), load it next to the new gate in a
  bare-Ruby script (rename the class to avoid the constant clash), and re-score the old saved
  reads through the OLD gate's logic. Join per-image on the filename, cross-tab old x new
  (held/published), and run the identity checks (old-held = still-held + released; old-published
  = still-published + newly-held) -- the checks catch join and aggregation bugs before the
  headline number.
- **Bare-Ruby load gotchas:** the gate file uses ActiveSupport, so shim what it needs
  (`String#present?`) before `load`; `Kernel#load` wants the exact path WITH the `.rb` extension
  (it does not append it).
- **The run is hours long** (~1 min/image on the brain, temp 0) -- launch it as a background
  process, ship code + CI first, and post the calibration as a follow-up ticket comment. A
  background completion notification does not say WHICH probe finished: check the process's output
  file and the question it used before quoting its numbers.

## Do not

- **Do not extend N after seeing the data.** If the effect is only "slightly better", calling it
  needs a bigger N, and that is a decision to take deliberately -- not by quietly adding seeds
  until something turns significant.
- **Do not read a partial result in either direction.** Unanswered pairs mean INCOMPLETE, not
  "trending".
- **Do not publish experiment assets as content.** A test run on an off-convention pose or an
  abandoned config exists to answer a question, not to post.
