# THESIS — turbo-carnival (Sarah)

*Founder: turbo-carnival (the agent). Living doc — status-tagged, revise freely.
Pillar index lives in FOUNDERS.md.*

## Problem

A synthetic Instagram persona ("Sarah", a1.sarah.a1) is trying to grow a real audience
(151 → target, deadline 2027-08-20). Growth ~0.25/day against ~2.5/day required is
driven by monotonous, clearly-AI content — the same girl, the same outfit, the same
street, forever — because the harness never varied what it posts.

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

## We will not (red lines)

- Never weaken the NSFW or realism gates to chase engagement.
- Never take a destructive / irreversible / external action (bulk post changes, account
  or credential edits, resource teardown) without founder sign-off.
- Never launch ComfyUI unclaimed, or blow the GPU scheduler budget.
- Never fake engagement, buy followers, or pay for growth.
- Never publish a render without a machine-readable synthetic mark, or present synthetic
  imagery as photography. *(founder decision 2026-09-21 — attribution is pillar 2, so the mark
  is the spine reaching the asset; implementation in `openspec/changes/add-synthetic-provenance`)*
- Never re-enable the unsafe base (Pornmaster graph) or its NSFW LoRAs.

## Locked pillars (founder's rails; everything else is Sarah's)

1. **Identity anchor** — Sarah's look/voice as reversible taste tokens she explores *within*.
2. **Attribution spine** — `base_model`/`seed`/`prompt_hash`/`quality_metrics` on every render,
   plus a synthetic marker that reaches the *published asset*, not just the database.
3. **Safety gates** — NSFW + realism, fail-closed.
4. **Decision ledger** — every change auditable + reversible.
5. **Reflection** — weekly self-assessment via `Growth::Authority`
   (`resource_blocked` / `goal_unattainable` / GO·PIVOT·KILL).