---
venture: turbo-carnival
source: docs/prd/0004-the-experiment-lane.md
---

# PRD 0005 — The revealing-miniskirt pillar: producible, postable, and does it land?

> **Status:** CURRENT · draft for founder review · 2026-10-19
> Lane: **PRD 0004** (the experiment contract) · Track: `experiment` · Folder: `experiments/0005-miniskirt-pillar/`
> **The day-to-day flow does not depend on this experiment.**

## The question

Two questions, answered in this order, because the second is moot if the first fails:

1. **Primary — can we produce it?** At what wardrobe intensity does a render stop clearing the gate that
   decides *"allowed to be posted to Instagram"*, and is there a rung on that ladder that is both
   genuinely revealing **and** postable at an acceptable rate?
2. **Secondary — does it land?** If such a rung exists and its posts are published, does that wardrobe
   earn more audience response than the mix it replaces?

*Observed, not built:* question 1 is answered by counting gate outcomes over a fixed render set; question 2
by platform response per published post over a fixed window.

## Founder rulings carried in

- **The goal:** *"generate images in revealing miniskirts, that are still legal and allowed to be posted to
  instagram."* (2026-10-19) That is the target. **This experiment does not extend it** — it measures where
  the boundary already is, and the top rung of the ladder is the founder's call, not the researcher's.
- Risk class 3 (explicitness / intensity) is a **founder ruling**, not a system decision
  (`AGENTS.md` → *the authority ladder*). The wardrobe axis may not be pushed further to improve a number.
- The persona is **18**, and the visuals must not *read* younger. **No wardrobe rung may trade against the
  age read**, and a rung that trends younger-looking is rejected regardless of its yield.

## The one varied axis

**The wardrobe descriptor — hemline length and coverage — in the scene text.** Five rungs, authored by the
researcher as coverage statements (which regions are covered, and how), not as mood words:

| rung | coverage intent |
|---|---|
| L1 | knee-length skirt, torso fully covered — the anchor, expected to pass |
| L2 | above-knee |
| L3 | mid-thigh |
| L4 | short — the rung the founder's wording points at |
| L5 | shortest plausible garment — expected to be the failing end |

L1 exists deliberately: **a ladder with no expected-pass rung cannot distinguish "the garment is
unpostable" from "the whole render path broke."** It is a positive control, not a sample.

## The held-fixed set — named, and asserted

Asserted before any render, and re-asserted per render:

- checkpoint, workflow file (sha256-pinned), scene look/pose/framing, resolution
- the identity block and the static face prompt — unchanged
- negative prompt — unchanged, with the coverage requirement **not** added here (see the fallback ladder)
- seed policy: the *same six seeds* used at every rung, so seed luck cancels across the ladder rather than
  between rungs
- caption style, cadence, time-of-day (for the secondary leg: unchanged from the existing mix)
- camera framing: the hemline is **not** the composition's subject — see the red lines

## The instrument

- **Primary: a closed-form count.** Per rung, the number of renders clearing every lane gate
  (`Growth::NsfwGate`, `Growth::PersonaAgeGate`, `Growth::RealismGate`, `Growth::NearDuplicateGate`) plus a
  present synthetic mark read back from the bytes. **No human ranking is required for the primary**, and
  none is requested — per PRD 0004, an experiment whose instrument is a count needs no eyes.
- **Secondary: platform response per published post**, over a fixed window, against a matched baseline.
  This instrument **does not exist yet** — it needs the per-asset attribution in W1.2 (PRD 0002).

## The decision rule — fixed before any render

**Design.** 5 rungs × 6 fresh seeds = **30 renders**, one scene, one checkpoint, one workflow sha. Cost:
~1 hour of 4090 time, no human attention for the primary. Axis-bite assertion: the wardrobe descriptor must
be **read back from the submitted payload** and diffed against the anchor rung before the yield is read —
this repo has already shipped a value that silently never reached the model, and a yield read on a
descriptor that never arrived is a measurement of the anchor, not of the rung.

**Primary rule, per rung (n = 6):**

| outcome | verdict for that rung |
|---|---|
| **6/6 or 5/6** clear every gate | **postable** |
| **4/6** | not a verdict → the pre-committed handling is to **re-run that rung and its neighbour with fresh seeds** (narrow the band), never to call it |
| **≤3/6** | **not postable** at that rung |

**Adoption rule for the pillar:** adopted iff **at least one rung above L1 is postable by the rule above**,
in which case the **highest postable rung** is the pillar's wardrobe. Rejected iff no rung above L1 reaches
5/6 across two rounds. **A rung is never re-worded mid-run to rescue its number** — a wording change makes
it a different rung and the run restarts.

**Pre-registered fallback if no rung above L1 is postable** (named now, so it cannot be invented later), in
order: (a) make the descriptor explicit about **coverage** — chest, pelvis, hemline — rather than relying on
a length adjective; (b) move the coverage requirement into the **negative**; (c) change the framing so the
garment is not the subject. Each is a **new run**, re-pre-registered, and none of them may push the
intensity target past the founder's ruling.

**Tie / indeterminate handling.** A render that fails a gate for an unrelated reason (a disabled limb, two
people in frame, an empty mask) is recorded as **`defect`, not `unpostable`** — it is excluded from the
yield denominator *and the exclusion is counted and reported*. A yield quoted over a silently shrunken
denominator is the failure the lane's incomplete-set rule exists to prevent.

**Stopping rule:** n = 6 per rung, plus at most one narrow-the-band re-run. **N is not extended after
seeing a number.**

## The legal floor is a gate, not an instrument

The single hard gate in this project (`AGENTS.md`): **adult (18+), no minor cues, no real-person likeness,
synthetic mark embedded.** This experiment may not treat a passing automated gate as *proof of legality* —
those gates are **proxies**, and the authoritative postability signal is a published post surviving on the
platform. Any framework that reads "the NSFW gate passed" as "this is allowed" is an agent-invented
equivalence, and it is forbidden here.

## The researcher

**One designated owner**, set when the ticket is claimed (status + `agent_working`), per PRD 0004. The
researcher owns this experiment end-to-end: designs the rungs, authors the descriptors, fires the renders,
reads the gates, records the verdict.

## Cost

| leg | cost |
|---|---|
| primary | ~30 renders, ~1 h of 4090 time, no human attention |
| secondary | publication of the adopted rung's posts + a fixed observation window; **blocked on W1.2 attribution** |

## The dependency claim

**The day-to-day flow does not depend on this experiment.**

- The primary leg touches only ComfyUI, and only while the researcher holds the card. It never kills,
  restarts or reconfigures a foreign holder.
- The secondary leg requires the pillar's posts to be **published**, which belongs to the day-to-day lane.
  The experiment therefore **files content requests into the same request queue production already
  consumes** — a contribution, never a control. Production consumes its own queue; if this experiment stops
  filing, production is unaffected and its queue simply has fewer entries.

## The exit

- **Adopted:** the highest postable rung becomes the pillar's wardrobe, recorded with the experiment id
  that caused it.
- **Rejected:** *no rung above L1 is postable at the pre-registered bar* — a **negative result**, which
  closes the item, with the design and the descriptors kept so the question is not silently re-run.
- **Indeterminate:** the narrow-the-band re-run is exhausted without leaving the 4/6 band → recorded as
  *the boundary is not resolvable at this n*, which is a finding, not a failure to be retried forever.

## Deletion test

Removing `experiments/0005-miniskirt-pillar/` must leave production unaffected: the renders and analysis
disappear, the adopted wardrobe — **if any** — is by then a value in the content configuration and does not
point at the folder, and production continues. Verified by deleting the folder in a scratch copy and
running the daily lane's own checks.

## Red lines

- **No wardrobe rung may be pushed further to improve a number.** Intensity is a founder ruling.
- **No rung may trade against the age read.** A rung that trends younger-looking is rejected regardless of
  yield — that is account-terminating, not a tuning trade-off.
- **The hemline is not the composition's subject.** Framing stays on the face and the persona; an
  experiment that turns into a garment catalogue is a different experiment and a different risk class.
- **A gate failure for an unrelated defect is not evidence about the garment**, and the excluded renders are
  counted and reported.
- **The synthetic mark is read back from the bytes**, not assumed because the pipeline is supposed to add it.
- **No descriptor change mid-run.** A changed descriptor is a new rung, a new pre-registration, a new run.
- **Never request human eyes for the primary.** It is a count, and spending attention on it would make the
  lane's cost depend on the founder — which PRD 0004 forbids.
- **A failing rung is not retried with more seeds** to reach a nicer number.

## Open questions

1. **Where does the ladder top out?** L4/L5 descriptions are the researcher's draft against the founder's
   wording; the *highest permitted intensity* is the founder's call. **Not decided here.**
2. **Is the secondary leg worth running before W1.2 lands?** Without per-asset attribution, an account-level
   response cannot be separated from the rest of the mix. *Lean: no — a confounded read is worse than no
   read, and the primary leg is independently useful.*
3. **Does a postable rung need a second scene before the pillar is adopted?** A single scene may make the
   pillar's yield specific to that composition. *Lean: adopt on one scene, then require a second scene
   before the pillar becomes a fixture of the mix.*
4. **If adopted, how is the pillar's wardrobe versioned?** The obvious home is the versioned content config
   in W1.2, so the pillar points at a version rather than at a folder (see the deletion test).

---
Drift note (gherkin-specialist): record every deviation when translating this into `.feature` files. The
scenarios carrying the weight are *a ladder with no expected-pass rung cannot distinguish an unpostable
garment from a broken render path* (the L1 control) and *a defect is excluded from the denominator and the
exclusion is counted*.
