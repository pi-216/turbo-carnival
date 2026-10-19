---
venture: turbo-carnival
source: PROJECT_PLAN
---

# PRD 0004 — The experiment lane: contrive, run on the side, decode, promote

> **Status:** CURRENT · draft for founder review · 2026-10-19
> Plan item: **W2** · Track: `experiment` · Must never block **W3**

## Summary

Build the capability to **contrive and run experiments beside the day-to-day lane** — so the system can
answer its own open questions without a human in the loop and without stalling production.

This PRD specifies the **lane**, not any experiment in it. It decides no content question and endorses no
prior conclusion. It is the machinery: how an experiment is formed, made safe to run off the critical
path, decoded into a verdict mechanically, and promoted on evidence.

## Founder rulings

Recorded because they are decisions, not preferences.

1. **"we need a way to contrive and run experiments on the side."** (2026-10-19) The lane is a standing
   capability of the system, not a project phase.
2. **The lane must never block the day-to-day lane.** *"Runs in parallel and must never block Block 2.
   Asks the founder only when it decides input is required; if the answer doesn't come, it **parks — it
   does not block**."* (2026-10-18)
3. **Promotion is automatic on a pre-registered threshold.** The founder is *"advisory input, not a
   gate."* A human-gated promotion would make this lane a longer route to the same bottleneck.
4. **The lane does not need permission to proceed.** *"You decide on the experiment."* The founder's role
   is the blinded ranking and the enablement the repo cannot supply — not approval of the design.
5. **Human input is requested as a ticket, not as a bottleneck.** *"when the team has time, create a
   ticket for him with a founder_needed label… he is willing to go to that ticket and do the ranking."*
6. **A ranking instrument is never a production gate.** *"elo-picker is never a blocker for posting.
   elo-picker can be a blocker for experiments."* An experiment may *declare* a ranking as its
   instrument; the posting path never inherits that dependency.
7. **Autonomy scales inversely with the downside.** *"no universal answer: If the model thinks the risk
   is too high, it waits for my input. If it is experimenting with new base models and found a way to
   ensure that the persona has all four limbs and exactly one hand: go with it."*

## Problem / motivation

Four findings from an inventory on 2026-10-19. These are findings about the **absence of the capability**;
none of them is a content conclusion, and none is a premise about what the content should be.

**1. The lane's rules live in prose, and prose does not survive a hand-off.** The strongest argument is
the repo's own code comment on `Growth::GateRead`:

> *"The gate was registered on the ops board as a criterion in PROSE… **Prose does not survive a
> hand-off.** … a reader who skips it reads a pre-intervention cohort as a strategy verdict, which is how
> a live experiment gets killed on evidence it could not have produced."*

That class exists because a criterion written in prose was re-read inconsistently by two different passes.
`GateRead` is the fix, and it is **the model for this PRD**: the rule became mechanical, testable, and
read-only.

**2. The lane's components exist as scattered scripts, not as one capability.** `scripts/` holds
`make_variant.py`, `replicate_pairs.py`, `contact_sheet.py`, and three per-experiment decoders
(`e2_decode.py`, `e3_decode.py`, `e4_decode.py`). Each is good; none is a lane. There is no single place
that says *how an experiment is formed, where its artifacts live, or what "done" means for one*. The
per-experiment decoders are the tell: **the decode step was re-implemented per experiment** instead of
being one instrument.

**3. There is no admission rule, so "an experiment" is whatever was last done by hand.** Nothing states
the conditions an experiment must satisfy to enter the lane — one axis, frozen held-fixed set, a decision
rule committed before data, a stopping rule, a named instrument. The render-side primitives *enforce*
pieces of this (a variant is refused unless exactly one leaf differs; a sheet is refused if any arm render
is missing), which shows the right shape. It is simply not the lane's stated contract.

**4. The lane has no defined relationship to the GPU or to production.** Serialization is real: the
brain and ComfyUI cannot be co-resident, and the day-to-day lane already contends for the same card. There
is a `Growth::SchedulerGate` and a file-based GPU scheduler with holder attribution. Nothing states that
the experiment lane **yields** — accepts pre-emption, recognises a foreign holder, and parks rather than
queues ahead of production work. Without that rule, "on the side" is a wish and the lane becomes a
contender.

## Goals / Non-goals

- **Goals**
  - An experiment is a **first-class, inspectable object** with a stable id, not a folder of scripts.
  - **Contriving** is a defined step with an admission rule a machine can check.
  - **Running on the side is structural**: the lane yields to production, can run with **no GPU at all**
    where the question allows, and **parks** rather than blocks when it needs a human.
  - **Decoding is mechanical**: one decode instrument, arithmetic in code, never recomputed from memory.
  - A verdict — **including a negative one** — closes the item.
  - Promotion into production happens on a pre-registered threshold, unattended.
- **Non-goals (explicit Out)**
  - **Out:** any specific experiment. This PRD decides no content, format, checkpoint, or strategy
    question.
  - **Out:** any production-path change. The lane may not alter what the day-to-day lane publishes.
  - **Out:** a general-purpose statistics library. The decode instrument handles this lane's designs.
  - **Out:** the Thinker. W1.1 supplies it; the lane must be runnable **without** it (see the ordering
    note), so the lane is not blocked behind a founder item.

## Scope — In / Out

**In:** the experiment record and its admission rule · the run path with its GPU-yield and park semantics
· one shared decode instrument · the artifact convention (where a run's outputs, blinding key, and pinned
workflow sha live) · the promotion rule · the lane's relationship to the ledger in
`docs/experiment-backlog.md`.

**Out:** the experiments themselves; the Thinker; venue work; the render rail's content; the retirement of
the in-app rating ladder (that is W1.2).

## Acceptance criteria

```gherkin
Scenario: an experiment cannot enter the lane malformed
  Given an experiment declaring two varied axes
  When it is submitted to the lane
  Then it is refused, and the refusal names both axes
  # the one-axis rule is mechanically enforced elsewhere in this repo already

Scenario: the decision rule is frozen before data
  Given an experiment whose decision rule or stopping rule is written after its first render
  Then the lane refuses the verdict as post-hoc
  And a pre-registered experiment cannot have its rule edited in place -- a change is a new experiment

Scenario: the lane yields to production
  Given production requires the GPU while an experiment run is in flight
  When the holder is production, or the operator's own interactive session
  Then the experiment stops at a safe boundary
  And it does not queue ahead of production work
  And it resumes or parks without human intervention

Scenario: the lane can run without a GPU
  Given an experiment whose question is answered by published-surface metrics or configuration
  Then it runs to a verdict with the GPU holder untouched

Scenario: needing a human parks, and never blocks
  Given an experiment that requires a blinded ranking
  When the ranking request is raised as a founder_needed ticket
  And no answer arrives
  Then the experiment parks in a visibly-parked state
  And no other lane item queues behind it
  # blocking is the failure mode this rule exists to prevent

Scenario: decoding is arithmetic, not judgement
  Given a completed run with its blinding key withheld
  When the decode instrument computes the verdict
  Then it reports the decision-rule arithmetic and the verdict from code
  And a declared tie counts as a non-preference
  And a failed one-sided test does not license the mirror claim

Scenario: a negative result closes the item
  Given an experiment whose verdict is "nothing established"
  Then the item is closed with the negative verdict recorded
  And the ledger retains the design, so the question is not silently re-run

Scenario: promotion is unattended
  Given an experiment whose verdict meets its pre-registered promotion threshold
  Then the winning configuration becomes the default without a human approval step
  And the promotion records which experiment caused it
```

## User stories / job-to-be-done

- As the **system**, I want to form and run an experiment without being designed by a human each time, so
  that progress is not gated on attention.
- As the **day-to-day lane**, I want the experiment lane to yield and park, so that curiosity cannot
  become an outage.
- As the **founder**, I want my eyes requested via a ticket I can pick up whenever, so that lending them
  is a contribution and never a blockage.
- As a **next agent**, I want the lane's admission and decode rules in code, so I cannot accidentally
  re-read a pre-registered rule as if it were a preference.
- As the **Director**, I want every verdict — including null results — on the record, so the same question
  is not re-run from scratch.

## Edge cases & red lines

- **A signal that is not a measurement must not produce a verdict.** The existing pre-registered read has
  an explicit third outcome meaning *"this leg is not yet a measurement — re-read, do NOT act"*, and it
  takes precedence over both pass and fail. Carry that shape into the lane: **an invalid measurement has a
  pre-committed handling, decided before the data.**
- **NULL is not 0.** A missing measurement collapsed to zero manufactures a result. Report unmeasured as
  unmeasured.
- **Pre-intervention data cannot testify about an intervention.** The lane must be able to state, for any
  verdict, the set that was eligible to vote — and must refuse rather than read a set that predates the
  change under test.
- **An incomplete run is never a smaller N.** A missing render, an aborted arm, or a partial set is a
  failure to report, not a result.
- **N is not extended after peeking.** If the pre-registered bar is not met, the verdict is "nothing
  established" — deliberately, and the design is recorded so a fresh pre-registration can follow.
- **No mirror claims.** A failed one-sided test in direction H does not license the opposite.
- **Blinding is real or it is nothing.** The key is withheld until the ranking is complete; a ranking tool
  that displays a filename carrying the condition is not blind, and the lane must know which condition it
  is in.
- **The lane does not touch production.** It may propose a promotion; it does not publish, and it may not
  edit the day-to-day lane's configuration in place.
- **Never request a ranking for a change that did not bite.** If an axis moved the artifact no more than
  run-to-run variation, the comparison is not rankable and asking for eyes is noise. The lane measures
  the axis before spending human attention.
- **The lane is not a place to park judgement.** "We will decide later" is not a verdict.

## Metrics / definition of done

- **Every experiment in the lane has a stable id, an admission-checked design, a pinned config, a frozen
  decision rule, and a recorded verdict** — including negatives.
- A malformed experiment is refused **by the lane**, demonstrated, not by a human noticing.
- An experiment run is **pre-empted by production without human intervention**, demonstrated.
- At least one experiment reaches a verdict with the **GPU untouched**.
- A parked-on-human experiment is **visible as parked**, and nothing queues behind it, demonstrated.
- One decode instrument serves the lane; per-experiment decoders are retired or reduced to thin adapters.
- A promoted configuration names the experiment that caused it.

## Salvage inventory — what already exists

Named because a capability built from scratch beside working primitives is how a repo ends up with two of
everything. Each item below exists today and is worth reusing **as-is** unless stated.

| what | where | reuse |
|---|---|---|
| Pre-registered gate as a **read**: frozen thresholds, a pre-committed handling for an invalid measurement, explicit confound accounting | `Growth::GateRead` | **The template for the lane.** Read-only, testable, safe at any time |
| One-axis enforcement: a variant is refused unless it differs in **exactly one leaf** | `scripts/make_variant.py` | as-is |
| Incomplete-set refusal + blind key emission | `scripts/replicate_pairs.py` | as-is |
| Arithmetic decoders (precedent for a single shared instrument) | `scripts/e{2,3,4}_decode.py` | **consolidate**, do not extend |
| Artifact convention: output root per run, blinding key, sha256-pinned workflow, contact sheets | `elo/`, `scripts/contact_sheet.py` | formalise as the lane's convention |
| GPU contention + holder attribution; yield semantics | `Growth::SchedulerGate`, file-based GPU scheduler | as-is |
| Bounded reversible mutation with a pre-registered gate and automatic revert | `Growth::PersonaEvolution` | as-is — the promotion precedent |
| The ledger | `docs/experiment-backlog.md` | becomes the lane's record; one entry per experiment |

## Open questions

1. **Does the lane inherit the parked pre-registered render experiment, or start clean?** The plan carries
   one un-run item (`W2.1`). The reset says the lane is specced fresh; whether that parked item is kept,
   re-pre-registered, or dropped is the founder's call and is **not decided here**.
2. **How does a GPU-yielding run stop "at a safe boundary"?** Options: only between renders; only between
   an arm's renders; or a checkpointed resume. *Lean: between renders, with the run recording the set it
   completed — an experiment that resumes mid-render risks a mixed batch, which is the failure the
   immutable-workflow rule already exists to prevent.*
3. **Does the lane get its own board Track lane or share `experiment`?** The board already has an
   `experiment` Track option. *Lean: share it — one field, and a separate lane would let an experiment be
   in two places.*
4. **How much of the decode instrument generalises?** Sign tests with a declared tie convention cover the
   paired designs seen so far. *Lean: fix that family first and refuse anything outside it explicitly,
   rather than growing a general stats surface nothing else needs.*

---
Drift note (gherkin-specialist): record every deviation when translating this into `.feature` files. The
scenarios that carry the weight are *an experiment cannot enter the lane malformed* and *needing a human
parks, and never blocks* — the second is the one that keeps this lane from becoming an outage.
