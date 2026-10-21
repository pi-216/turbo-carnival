---
venture: turbo-carnival
source: PROJECT_PLAN
---

# PRD 0004 — The experiment lane: the contract every experiment must satisfy

> **Status:** CURRENT · founder constraints incorporated 2026-10-19 · ready to cut tickets
> Plan item: **W2.1** · Track: `experiment` · **The day-to-day flow never depends on an experiment**

## Summary

This PRD specifies the **lane** — the standing contract and machinery for experimenting — and no
experiment in it. **Each experiment gets its own PRD**, its own code folder, its own researcher, and its
own tickets; this document is what those PRDs must satisfy.

An experiment is a bounded, self-contained piece of research: it asks one question, generates whatever it
needs (test images, a configuration, a cohort), evaluates the result, and reaches a verdict — **including a
negative one**. Everything it needs lives inside it. Nothing in the day-to-day flow ever waits on it.

## Founder rulings

Recorded verbatim where stated, because they are decisions and not preferences to be re-litigated.

1. **"we need a way to contrive and run experiments on the side."** (2026-10-19) A standing capability.
2. **"'On the side' means: the day to day flow does not depend on an experiment."** (2026-10-19) — the
   defining constraint. It is a **one-way dependency rule**, not merely a scheduling preference.
3. **"Experiments need their own PRDs."** (2026-10-19)
4. **"Their code live in `experiments/0007-prd-slug` subfolders."** (2026-10-19) One folder per experiment,
   named for its PRD.
5. **"Experiments are done by a designated researcher."** (2026-10-19) One experiment, one owner.
6. **"The researcher should have access to ComfyUI."** (2026-10-19) The lane is not GPU-starved; it is
   dependency-isolated. It must not disturb the holder.
7. **"The thinker can suggest to run an experiment — 'try a miniskirt pillar' — and see if people react to
   it."** (2026-10-19) Proposals come from the Thinker, and a question may be about **audience reaction**,
   not only about render quality.
8. **"Evaluating the data, generating the test images, asking me for an eye or elo ranking, etc all live
   within the experiment."** (2026-10-19) The experiment owns its whole lifecycle, including the request
   for human eyes.
9. **Promotion is automatic on a pre-registered threshold** — the founder is *"advisory input, not a
   gate."* A human-gated promotion would make the lane a longer route to the same bottleneck. (2026-10-18)
10. **A ranking instrument is never a production gate.** *"elo-picker is never a blocker for posting.
    elo-picker can be a blocker for experiments."* An experiment may *declare* a ranking as its
    instrument; the posting path never inherits that dependency. (2026-10-19)
11. **The lane does not need permission to proceed.** *"You decide on the experiment."* The founder's role
    is the blinded ranking and the enablement the repo cannot supply — not approval of the design. (2026-10-18)
12. **"The brain or experimenter should know that the existing pillars are fair game."** (2026-10-19) An
    experiment may target an **existing** content pillar — re-scope it, replace its wardrobe, retire it — and
    not only propose a new one. The pillar set is class 2 (`AGENTS.md` → *the authority ladder*), so *"should
    this pillar exist at all?"* is inside the lane's remit; what a pillar **depicts** stays class 3–4, but
    under PRD 0007 A5 only class 4 stops: intensity (class 3) is the system's — measured, bounded by the
    legal floor, with the A5 tier pre-flight at each tier start — while the persona's identity and age read
    (class 4) still stop for a founder ruling.

## Problem / motivation

Five findings from an inventory on 2026-10-19. These are findings about the **absence of the capability**.
None is a content conclusion and none is a premise about what the content should be.

**1. The lane's rules live in prose, and prose does not survive a hand-off.** The repo's own code makes
this argument better than this PRD can — from `Growth::GateRead`:

> *"The gate was registered on the ops board as a criterion in PROSE… **Prose does not survive a
> hand-off.** … a reader who skips it reads a pre-intervention cohort as a strategy verdict, which is how
> a live experiment gets killed on evidence it could not have produced."*

**2. There is no convention for where an experiment lives.** Experiment code is spread across `scripts/`
(`make_variant.py`, `replicate_pairs.py`, three separate decoders, traces) and artifacts across `elo/` and
`tmp/`. Nothing ties a piece of code to the question it answers. The three decoders are the tell: **the
decode step was re-implemented per experiment** because there was nowhere for an experiment to own it.

**3. There is no admission rule, so "an experiment" is whatever was last done by hand.** Nothing states
the conditions an experiment must satisfy to exist — one varied axis, a frozen held-fixed set, a decision
rule committed before data, a stopping rule, a named instrument, an owner.

**4. There is no stated dependency direction.** The rule that matters most is not about the GPU; it is
that **nothing in the day-to-day flow may wait on an experiment**. Today that is a habit, not a checkable
property — and an experiment that has been abandoned, parked, or deleted must leave the daily flow
completely unaffected.

**5. There is no defined researcher role.** An experiment has no owner, so two agents can work the same
question, or none can. The board's claim mechanism exists (`agent_working` + status), but nothing says an
experiment is a **unit of ownership**.

## What every experiment PRD must contain

The lane's real deliverable. A PRD that omits any of these is refused **by the lane**, not by a human
noticing.

| field | rule |
|---|---|
| **id + slug** | a PRD number; the folder is `experiments/<PRD-number>-<slug>/` |
| **The question** | one sentence, in terms of what would be *observed*, not what would be *built* |
| **The one varied axis** | exactly one. Enforced mechanically where the artifact is a file |
| **The held-fixed set** | named, and asserted not to have drifted between arms |
| **The instrument** | how the outcome is read: a blinded human ranking, elo-picker, platform metrics, or a closed-form count. If a ranking is required, that requirement is **declared here** |
| **Primary and secondary legs** | which outcome decides the verdict, and which is merely recorded. **A secondary can never rescue a losing primary.** Any leg may be parked on a dependency while the primary still runs |
| **How the intervention reaches the published surface** | if the intervention must be *published* to be observed, name the mechanism — and it must be a **contribution to the production queue production already reads**, never a control of it. Production must be unaffected if the experiment stops filing |
| **The attribution requirement** | how a published outcome is tied back to this experiment, and which piece of infrastructure that needs. If it needs something unbuilt, the leg **parks** rather than being read confounded |
| **Does it touch the legal floor or the intensity ladder?** | if yes, state that the floor is a **gate, not an instrument**, and that automated gates are **proxies, not proof** of postability |
| **The positive control** | at least one arm whose outcome is known in advance. Without one, "everything failed" cannot be distinguished from a broken render path or a value that never reached the model |
| **The decision rule** | fixed **before** any data, including the tie convention, the stopping rule (N), and the rule that a failed one-sided test does not license the mirror claim |
| **The handling of an invalid measurement** | pre-committed. The existing pre-registered read has a third outcome meaning *"not a measurement yet — re-read, do NOT act"*, and it outranks both pass and fail |
| **Cost + budget** | GPU time, human attention, wall-clock |
| **The researcher** | the designated owner |
| **The dependency claim** | an explicit statement that the day-to-day flow does not depend on this experiment |
| **The exit** | what "done" means, including *nothing established* |
| **Deletion test** | the experiment must be removable without touching production |

**Five of those fields were added after the first application, not from review.** Applying this contract to
`0005` (the revealing-miniskirt pillar) exposed that it had no field for how an intervention reaches the
published surface, no primary/secondary distinction, no attribution requirement, no relationship to the hard
gate, and no positive control. A contract that has never been applied once is unvalidated — expect the next
experiment to expose more, and amend this list rather than letting a field be skipped.

## Roles

| role | does | does not |
|---|---|---|
| **Thinker** (W1.1) | proposes experiments as hypotheses — *"try a miniskirt pillar and see if people react"*, or a change to a pillar that already exists | design the test, or run it |
| **Researcher** (designated) | owns one experiment end-to-end: designs it, writes its PRD, generates its artifacts, evaluates, decodes, records the verdict | touch the day-to-day lane's configuration, or publish |
| **Founder** | lends eyes; ranks blind; supplies enablement the repo cannot; **advisory input, never a gate** | approve designs, gate promotion, or be a required step |
| **Day-to-day lane** | runs and posts, unaffected | — it may never depend on an experiment |

The lane must be runnable **without** the Thinker (which is blocked on a founder item today), so a
founder-or-agent proposal path exists alongside it.

## Goals / Non-goals

- **Goals**
  - An experiment is a **first-class object**: own PRD, own folder, own researcher, own tickets.
  - **Contriving** is a defined step with an admission rule a machine checks.
  - **Isolation is structural**: *nothing* in the daily flow depends on an experiment, and deleting an
    experiment leaves production untouched.
  - **Decoding is mechanical**: one shared instrument, arithmetic in code, never recomputed from memory.
  - A verdict — **including a negative one** — closes the item.
  - Promotion happens on a pre-registered threshold, unattended.
- **Non-goals (explicit Out)**
  - **Out:** any specific experiment, and any content, format, checkpoint, or strategy conclusion.
  - **Out:** any change to the production path. The lane may propose a promotion; it never publishes and
    never edits the daily configuration in place.
  - **Out:** a general-purpose statistics surface. The decode instrument covers this lane's designs and
    **refuses** anything outside them, explicitly.
  - **Out:** the Thinker itself. W1.1 supplies it.

## Scope — In / Out

**In:** the experiment PRD contract above · the `experiments/<PRD-number>-<slug>/` convention · the
researcher role and its claim semantics · one shared decode instrument · the promotion rule · the
isolation guarantee and its test · the relationship to the ledger in `docs/experiment-backlog.md`.

**Out:** the experiments themselves; the Thinker; venue work; the render rail's content; retiring the
in-app rating ladder (W1.2).

## Acceptance criteria

```gherkin
Scenario: the daily flow cannot depend on an experiment
  Given an experiment that is parked, broken, or deleted outright
  When the day-to-day lane runs
  Then it completes unaffected, with no error and no wait
  # this is the definition of "on the side"; it is a property, not a hope

Scenario: an experiment owns its own lifecycle
  Given a running experiment
  Then its PRD, code, test artifacts, decoder and verdict all resolve from its PRD number
  And no part of it lives in a shared production directory
  And removing experiments/<PRD-number>-<slug>/ leaves production untouched

Scenario: an experiment cannot enter the lane malformed
  Given an experiment declaring two varied axes
  When it is submitted to the lane
  Then it is refused, and the refusal names both axes
  And given an experiment with no designated researcher, it is refused

Scenario: the decision rule is frozen before data
  Given an experiment whose decision rule or stopping rule is written after its first artifact
  Then the lane refuses the verdict as post-hoc
  And a pre-registered experiment cannot have its rule edited in place -- a change is a new experiment

Scenario: a signal that is not a measurement produces no verdict
  Given an experiment whose eligible set is too small, or predates the change under test
  Then the outcome is the pre-committed "not a measurement yet" handling
  And it does not report pass or fail

Scenario: evaluating data, generating images and asking for a ranking all live inside the experiment
  Given an experiment requiring a blinded human ranking
  Then the ranking request is raised as its OWN founder_needed ticket, referencing its PRD
  And the experiment parks in a visibly-parked state if no answer arrives
  And no item in the day-to-day lane queues behind it

Scenario: decoding is arithmetic, not judgement
  Given a completed experiment with its blinding key withheld
  When the decode instrument computes the verdict
  Then it reports the decision-rule arithmetic and the verdict from code
  And a declared tie counts as a non-preference
  And a failed one-sided test does not license the mirror claim

Scenario: a negative result closes the item
  Given an experiment whose verdict is "nothing established"
  Then it is closed with the negative verdict recorded
  And the ledger keeps the design, so the question is not silently re-run

Scenario: the researcher has GPU access without disturbing the holder
  Given the researcher runs an experiment that needs ComfyUI
  And another holder owns the card
  Then the experiment does not kill, restart or reconfigure that instance
  And it waits or parks without human intervention

Scenario: promotion is unattended
  Given an experiment whose verdict meets its pre-registered promotion threshold
  Then the winning configuration becomes the default without a human approval step
  And the promotion names the experiment that caused it
```

## User stories / job-to-be-done

- As the **system**, I want to form and run an experiment without a human designing each one, so progress
  is not gated on attention.
- As the **day-to-day lane**, I want a guarantee that nothing waits on research, so curiosity can never
  become an outage.
- As a **researcher**, I want one experiment I own completely, so two agents cannot collide on a question
  and none can be left unowned.
- As the **founder**, I want my eyes requested via a ticket I pick up whenever, so lending them is a
  contribution and never a blockage.
- As a **next agent**, I want the lane's admission and decode rules in code, so I cannot re-read a
  pre-registered rule as a preference.

## Edge cases & red lines

- **Isolation is one-way and absolute.** Experiments may read the day-to-day lane's outputs (a published
  post's metrics, a render's provenance). **Nothing in the daily flow may read from, wait on, or be
  configured by an experiment.** This is the whole of "on the side".
- **An experiment must be deletable.** If removing `experiments/<n>-<slug>/` changes production behaviour,
  the experiment has leaked into the production path — that is a defect, not a style issue.
- **A signal that is not a measurement must not produce a verdict.** An invalid measurement has a
  pre-committed handling, decided before the data. It outranks pass and fail.
- **NULL is not 0.** A missing measurement collapsed to zero manufactures a result.
- **Pre-intervention data cannot testify about an intervention.** The lane must state, for any verdict,
  the set eligible to vote — and refuse rather than read a set that predates the change under test.
- **An incomplete run is never a smaller N.** A missing artifact or an aborted arm is a failure to report.
- **N is not extended after peeking**, and **no mirror claims**: a failed one-sided test in direction H
  does not license the opposite.
- **Blinding is real or it is nothing.** The key is withheld until the ranking completes. A ranking tool
  that shows a filename carrying the condition is not blind, and the lane must know which it is in.
- **Never ask for eyes on a change that did not bite.** If the axis moved the artifact no more than
  run-to-run variation, the comparison is not rankable, and requesting a ranking spends human attention on
  noise. Measure the axis before spending it.
- **The lane is not a second `scripts/`.** Shared machinery belongs to the lane; experiment-specific code
  belongs to the experiment. When two experiments need the same decoder, the decoder is promoted to the
  lane rather than copied.
- **The researcher does not own production.** Access to ComfyUI is not authority over it: never kill,
  restart or reconfigure a foreign holder.
- **"We will decide later" is not a verdict.**

## Metrics / definition of done

- Every experiment has **its own PRD**, a folder `experiments/<PRD-number>-<slug>/`, a designated
  researcher, and a recorded verdict — **including negatives**.
- **The isolation test passes**: parking, breaking, or deleting an experiment leaves the day-to-day lane
  unaffected, demonstrated.
- A malformed experiment is refused **by the lane**, demonstrated — not caught by a human.
- An experiment reaches a verdict with the GPU untouched (a question answered from platform metrics or
  configuration).
- One decode instrument serves the lane; the per-experiment decoders are consolidated and anything outside
  its design family is refused explicitly.
- A promoted configuration names the experiment that caused it.
- The ledger carries one entry per experiment, each pointing at its PRD and its folder.

## Salvage inventory — what already exists

Named because building a capability from scratch beside working primitives is how a repo ends up with two
of everything. Each exists today; reuse **as-is** unless stated.

| what | where | reuse |
|---|---|---|
| Pre-registered gate as a **read**: frozen thresholds, a pre-committed handling for an invalid measurement, explicit confound accounting, NULL ≠ 0 | `Growth::GateRead` | **the template for the lane.** Read-only, testable, safe at any time |
| One-axis enforcement: a variant is refused unless it differs in **exactly one leaf** | `scripts/make_variant.py` | as-is |
| Incomplete-set refusal + blind key emission | `scripts/replicate_pairs.py` | as-is |
| Arithmetic decoders (the precedent for one shared instrument) | `scripts/e{2,3,4}_decode.py` | **consolidate**, do not extend |
| Blinding keys, sha256-pinned workflows, contact sheets, per-run output roots | `elo/`, `scripts/contact_sheet.py` | formalise under the new folder convention |
| GPU contention, holder attribution, yield semantics | `Growth::SchedulerGate`, file-based GPU scheduler | as-is |
| Bounded reversible mutation with a pre-registered gate and automatic revert | `Growth::PersonaEvolution` | as-is — the promotion precedent |
| The ledger | `docs/experiment-backlog.md` | one entry per experiment, each pointing at its PRD |

## Open questions

1. **Does the lane inherit the parked render experiment, or start clean?** Under this PRD that experiment
   would need **its own PRD** to run at all. Whether it is kept, re-registered, or dropped is the
   **founder's call**, and is deliberately not decided here or by an agent.
2. **Does every experiment need human eyes, or only those whose instrument is a ranking?** Experiments read
   from platform metrics or a closed-form count need no human at all. *Lean: no — requiring a ranking
   universally would make the founder a bottleneck for the whole lane, which ruling 9 forbids.*
3. **How far does the one-folder rule reach?** A render experiment's pools are large and currently live
   outside it. *Lean: the folder holds code, configs, decoders and verdicts; large artifact pools may live
   under it or be referenced by sha — but the reference must resolve from the PRD number.*
4. **Does the researcher role need its own board label, or is `agent_working` + assignment enough?**
   *Lean: enough — a second mechanism for the same claim invites two sources of truth.*

---
Drift note (gherkin-specialist): record every deviation when translating this into `.feature` files. The
two scenarios carrying the weight are *the daily flow cannot depend on an experiment* — the definition of
"on the side" — and *an experiment owns its own lifecycle*, which is what makes deletion safe.
