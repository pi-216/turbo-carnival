# THESIS — turbo-carnival (Sarah)

> **Status:** CURRENT — the live thesis: problem / user / value, the founder's red lines, and the locked pillars
>
> Rebased to CURRENT 2026-10-21 (PRD 0006 F7, ticket #81). The HISTORICAL revision
> (2026-09-17 → 2026-10-18) is recoverable from git history; its agent-authored red lines were
> withdrawn 2026-10-18 (`strategy-v2.md` §12.3) and do not come back. Every line of the
> "We will NOT" list below cites the founder source that set it — a red line that cannot cite a
> founder source does not belong here (the test in `strategy-v2.md` §12.3).
>
> The distribution diagnosis, the venue design, and the platform findings live in
> `docs/strategy-v2.md`. This file does not duplicate them.

## Problem

A synthetic Instagram persona ("Sarah", a1.sarah.a1) is trying to grow a real audience —
1,000 followers by 2027-08-20. The binding constraint is content, not compute or cadence:
monotonous, clearly-AI output (the same girl, the same outfit, the same street) does not earn
the audience. The distribution diagnosis and the venue design are in `docs/strategy-v2.md`.

## User

People who follow because they want to *know a person*, not watch a factory render the
same image on a loop.

## Value

An authentic-feeling identity: **consistency and variety** — a "real" person who
changes, experiments, and responds to what her audience rewards.

## The experiment

Content variety — style, topics, captions, skin shown — **discovered and evolved by
Sarah, not handed down as a fixed list.** Growth is the metric; the axes are hers to
find and own.

## We will NOT (founder's red lines)

The legal floor (`PRD 0007` §1) leads: it is the only part of this list that is
**fail-closed**, and the only part that may be phrased as a gate. The rest are founder-authored
invariants. An agent's safety preference is not a red line in this file — it is a control, and
it is triaged where controls are triaged (`PRD 0007`).

### The legal floor (PRD 0007 §1)

1. **We will NOT publish a render that reads as a minor.** The persona is an 18-year-old
   adult, and the target read is 18–20 — that is what the followers are for. A render that
   *looks like a minor* is a miss at every wardrobe tier. (PRD 0007 §0, §1.)
2. **We will NOT use a real-person likeness.** The face is a synthetic identity (sarah1a3),
   never a real person. (PRD 0007 §1.)
3. **We will NOT publish an asset without a machine-readable synthetic mark and a
   self-disclosure path.** Provenance is embedded in the asset and disclosure is enforced at
   publish. (Founder decision 2026-09-21; PRD 0007 §1.)
4. **We will NOT jeopardize account survival (platform compliance).** No duplicate content,
   no faked or bought engagement; pacing stays within the platform's measured tolerance.
   (PRD 0007 §1, B4.)

### The founder's invariants (strategy-v2 §5)

5. **We will NOT take a destructive, irreversible, or external write without the founder's
   explicit sign-off** (bulk post changes, account or credential edits, resource teardown).
6. **We will NOT launch ComfyUI unclaimed or blow the GPU scheduler's budget.**
7. **We will NOT conflate the model's hedging with the gate.** Uncensored ≠ explicit: the
   model *writes* unhedged; the *gate* decides what publishes.
8. **We will NOT let a quality control veto content.** Instruments and selectors (human
   rating, identity similarity, genetic search) are never blockers; the one exception is the
   legal floor. (founder, 2026-10-18.)

### Identity (class 4)

9. **We will NOT move the persona's identity (Sarah, 18).** That is a ruling, not a
   measurement: class 4 in the authority ladder stays with the founder
   ("The persona is 18 — that is where the line stands", PRD 0007 §0 / `strategy-v2.md` §12.3).

## Locked pillars (founder's rails; everything else is Sarah's)

Founder ruling 2026-10-19 (`AGENTS.md` → *the authority ladder*): these five rails stay
locked. The **content** pillars — which mix of topics Sarah posts — are class-2 levers, not
rails, and are not locked.

1. **Identity anchor** — Sarah's look/voice as reversible taste tokens she explores *within*.
2. **Attribution spine** — `base_model`/`seed`/`prompt_hash`/`quality_metrics` on every render,
   plus a synthetic marker that reaches the *published asset*, not just the database.
3. **Safety gates** — the legal floor (PRD 0007 §1) stays fail-closed; every other control is
   an advisory measurement that is recorded, not a veto (PRD 0007 A1/B3).
4. **Decision ledger** — every change auditable + reversible.
5. **Reflection** — weekly self-assessment via `Growth::Authority`
   (`resource_blocked` / `goal_unattainable` / GO·PIVOT·KILL).
