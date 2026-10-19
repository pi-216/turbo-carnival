---
venture: turbo-carnival
source: strategy-v2
---

# PRD 0002 — The versioned content config, and the experiment DB spine

> **Status:** CURRENT · draft for founder review · 2026-10-18
> Plan item: **W1.2** · Track: `core-infrastructure` · Blocks: all of W2, all of W3

## Summary

Make every render and every published asset **attributable** — what produced it, how it was judged, and
how it did — and make the content configuration a **first-class version** that Block 2 points at, so that
a change in engagement can be traced to the change that caused it.

This is a **migration, not a greenfield schema**. The tables exist; what is missing is that the raw inputs
live in JSON blobs, and that the primary instrument is measured at the wrong level.

## Problem / motivation

Five specific gaps, each verified against `db/schema.rb` on 2026-10-18 — not inferred:

**1. The primary instrument does not exist per asset.** `non_follower_reach` is a column on
**`growth_snapshots`** — an account-level aggregate over a time window. It is *not* on `scheduling_posts`,
which carries only `reach` (total), `likes_count`, `comments_count`, `saved_count`, `engagement_rate`.
So the strategy's stated primary metric — the only number that has ever moved, and the only one that
measures discovery — **cannot be attributed to an individual asset by construction.** Every
"which content earns reach" question is currently unanswerable, not merely awkward.

**2. The inputs are in blobs, so nothing is a query.** No `base_model`, `seed`, `prompt_hash`,
`prompt_parts`, `workflow_sha`, `checkpoint`, `loras`, or `sha256` column exists anywhere in the schema.
What exists instead:

| where | what it holds | why it isn't enough |
|---|---|---|
| `pipeline_runs.variables` jsonb (GIN) | the token substitutions — including seed and checkpoint | a blob: not groupable, not joinable, no constraint |
| `pipeline_runs.prompt` (text) | the assembled prompt | **assembled** — an outcome is attributable only to "the prompt", which is not a thing you can change |
| `pipeline_steps.comfy_workflow_json` (text) | the graph | the graph now *also* lives in git (`comfy_workflows/`) — two copies, no stated authority |
| `image_candidates.quality_metrics` jsonb | `blur_score, contrast, brightness, width, height, issues` | a technical battery; not identity, realism, aesthetic, or cover-frame risk |
| `pipeline_runs.quality_metrics` jsonb | same shape | same |

**3. A second rating system already exists — the exact thing we said not to build.** `image_candidates`
carries `elo_score` (int, default 1000), `vote_count`, `winner`, `winner_at`, `engagement_score`, plus
`parent_id`/`child_count` — i.e. **an ELO ladder and a breeding tree, inside turbo-carnival.** Meanwhile
elo-picker keys its own `images` table on `sha256` with `elo`, `rd`, `wins`, `losses`, `draws`.
Strategy v2 §12.2: *"join to elo-picker on `sha256` as an external control, or absorb its schema. Do not
build a second rating system."* We have two, and the decision was never made.

**4. `photos.provenance` is not render attribution — do not overload it.** Read the code and it is a
**compliance ledger**: `provenance['embedded']` records whether the synthetic mark was written into the
asset, and `ContentPillars::PhotoProvenance` exists to satisfy the legal floor. Reusing that column for
"which checkpoint produced this" would mix a legal record with an experiment record, and the legal one
must not be collateral damage of a schema migration.

**5. Nothing pins "the configuration that produced this asset".** The config is currently spread across
`content_pillars` rows (with `start_date`/`end_date` and a `weight`), scene files in `scenes/`, and the
workflow graph. A run records `pipeline_id`, `persona_id`, `content_pillar_id` — and nothing that says
*which version of the configuration* it ran under. So a metric that moves cannot be attributed to a change.

Founder, 2026-10-18: *"We must collect and persist as much raw information as possible: models, prompts,
prompt parts, seeds, time of day posted, day of week posted, all of it."* — and note **prompt parts**, not
the assembled prompt: each part has to be a **named, addressable field**, or it cannot be varied.

## Goals / Non-goals

- **Goals**
  - A render's full input set is recoverable as **rows and columns**, not a blob.
  - ~~`non_follower_reach` is available **per published asset**, not only per account-window.~~
    **Corrected by measurement, 2026-10-19 (founder ruling: option B):** Instagram exposes **no**
    per-post follower/non-follower split. Every media-level `follow_type` breakdown answers
    `400 (#100)` on v19.0–v24.0 while the account-level one answers `200`. The per-post instrument is
    therefore the metrics the platform *does* report per post — **`reach`, `views`, `follows` and
    `profile_visits`** (the last two on FEED media only) — and `non_follower_reach` stays an
    **account/day** measurement. Deriving a per-post split was rejected: it would put an attributed
    number in a column whose name implies the platform measured it.
  - A **content config version** exists as an immutable object; every run references it; Block 2 points
    at one version.
  - One query answers: *which checkpoint / LoRA / sampler / prompt-part combination produced the assets
    that earned the most reach?* — the join is `sha256`.
  - **elo-picker is the rating instrument.** The in-app ladder is **retired rather than maintained** as a
    second one. It never blocks posting; it may block an experiment that declares it as its instrument.
  - One rating store, or a documented relationship between two — never an undocumented third.
- **Non-goals (explicit Out)**
  - **Out:** any change to the render graph, the scene text, or the image stack.
  - **Out:** building the Thinker, or any generator of prompts. This PRD stores what was generated.
  - **Out:** the synthetic-mark requirement, which stays exactly as it is (it is the legal floor).
  - **Out:** the second venue/persona.
  - **Out:** a second rating *UI*. elo-picker already has voting; this PRD is about the schema behind it.

## Scope — In / Out

**In:** the normalized attribution spine (assets / renders / prompt parts / assessments); the per-post
instrument (`reach`, `views`, `follows`, `profile_visits`); the immutable content-config version; the
experiment record; backfill policy for
existing rows; the elo-picker relationship decision.

**Out:** dashboard/UI work beyond what already exists, prompt authoring, venue B, the brain.

## Acceptance criteria

```gherkin
Scenario: a render's inputs are recoverable as data
  Given a render exists
  When I ask what produced it
  Then I get checkpoint, LoRA set with strengths, seed, the prompt PARTS as named fields,
       the negative, sampler, steps, cfg, denoise, resolution, and the workflow sha
  And none of it requires parsing a JSON blob to answer

Scenario: the per-post instrument attaches to an asset
  Given an asset has been published
  When its metrics are collected
  Then reach and views are stored PER POST
  And follows and profile_visits are stored where the media type supports them
  And a metric the platform does not report is stored as NULL, never as 0
  And a query groups reach by the render that produced it without a manual mapping step

Scenario: the content config is a version, and runs reference it
  Given a content config version exists
  When a render is created
  Then the run references that version's id
  And the version is immutable — editing the config produces a NEW version, never a mutation

Scenario: a config change is attributable
  Given two content config versions have each produced published assets
  When I compare their outcomes
  Then the comparison is a query over versions and metrics
  And no human has to reconstruct which assets belonged to which change

Scenario: an experiment records one axis and a verdict
  Given an experiment is registered
  Then it names the single varied axis, the held-fixed set, and the decision rule
  And its verdict, when recorded, is readable next to its pre-registration

Scenario: elo-picker never blocks posting
  Given elo-picker is unreachable, or holds no rating for an asset
  When the day-to-day path renders and posts
  Then it proceeds unaffected
  And the missing rating is recorded as NULL — never as zero, and never as an error

Scenario: an experiment may wait for its instrument, and only itself
  Given an experiment has declared a ranking as its instrument
  When that ranking does not yet exist
  Then the experiment parks and reports that it is waiting
  And the posting path is unaffected by that wait
  And nothing else queues behind it

Scenario: the existing rows are not corrupted by the migration
  Given rows predating this schema
  Then their missing attribution reads as unknown
  And no value is inferred, defaulted, or invented to fill a provenance gap
```

## User stories / job-to-be-done

- As the **Thinker**, I want to know which of my choices produced the reach, so that a hypothesis can be
  confirmed or killed instead of re-guessed.
- As the **founder**, I want to re-rank the same assets later without re-rendering, so that taste and
  audience outcome accumulate as separate measurements on one set.
- As a **next agent**, I want the prompt in parts, so that I can vary one of them.
- As the **Director**, I want to know which version of the config is live, so that a metric shift has an
  address.

## Edge cases & red lines

- **`photos.provenance` is a compliance record.** It stays separate from the attribution spine. A
  migration that touches it is out of scope.
- **Never invent provenance.** The corpus carries hundreds of existing posts and thousands of candidates
  with no recorded inputs. Backfill is **best-effort and explicitly nullable**; a guessed checkpoint is
  worse than an absent one, because it silently poisons every later query.
- **The version is immutable.** If a version can be edited in place, attribution dies retroactively —
  the same failure as the DB-only workflow column that this project already fixed once by moving the
  graph into git.
- **elo-picker never blocks posting; it may block an experiment.** Founder, 2026-10-19: *"elo-picker is
  never a blocker for posting. elo-picker can be a blocker for experiments."*
  - **Day-to-day (posting):** ratings are an **optional join**. Absent is a normal state, not an error.
    **No code path in the content pipeline may order or gate its work on whether a rating exists.**
  - **Experiments:** an experiment may declare a ranking as *its instrument* and **park** until that
    ranking exists. That is its own dependency, declared in its pre-registration — never inherited by the
    posting path.
  The distinction must be **explicit in the experiment record**, or it leaks: an experiment's wait becomes
  a queue that the business quietly runs behind, which is the one thing Block 3 must never cause.
- **The spine is complete without elo-picker.** Every attribution and reach query answers with zero
  ratings present. If a query returns nothing without elo-picker, the join has become a dependency.
- **Retire the in-app ladder; do not silently drop it.** Stop reading and writing
  `image_candidates.elo_score` / `vote_count` / `winner`, **prove no readers remain**, export the values,
  and only then remove the columns — in their own ticket. Export-before-prune ordering matters here: this
  table also holds a parent/child breeding tree, so a dropped column is irreversible data loss.
- **Do not add a third rating store.** With elo-picker as the instrument, this PRD's job is to make the
  spine complete *without* one.
- **The primary metric is `reach` per post, and `non_follower_reach` per account-day.** A schema that
  makes either awkward to query is wrong even if it is complete. (Per-post non-follower reach is not
  obtainable from the platform — see the correction under Goals.)
- Time-of-day and weekday are **constants today** (posting is cron-pinned), so they cannot teach anything
  yet. Record them — but mark them uninformative until something actually varies them, or a later reader
  will find a trend in a constant.

## Metrics / definition of done

- The one-query attribution question returns an answer for a real batch, with no blob parsing.
- `reach` and `views` present per post for at least one published batch, `follows` / `profile_visits`
  where the media type supports them, and **`non_follower_reach` present per account-day window**
  (per-post is not obtainable — see the correction under Goals). A metric the platform did not report
  reads as NULL, never 0.
- Every new render references a content config version id.
- The in-app ladder is **provably unread** (writes stopped, zero readers), and its values are exported
  before any column is removed.
- **With elo-picker stopped, a render → post cycle completes unscathed**, and the missing ratings appear
  as NULL rather than 0.
- An experiment that declares a ranking instrument parks visibly, and blocks nothing outside itself.
- An existing corpus row from before this PRD, queried through the new spine, returns **unknown**
  attribution rather than a fabricated one.

## Open questions

1. ~~**elo-picker: absorb or join?**~~ **Resolved by the founder, 2026-10-18:** *"drop the pre-existing.
   elo-picker is progressing faster. elo-picker can never be a blocker."* → **join on `sha256` and retire
   the in-app ladder.** The internal `elo_score` / `vote_count` / `winner` columns stop being read and
   written; elo-picker becomes the rating instrument. Retirement is sequenced (see the red lines):
   stop using → prove no readers → export → remove. Not a silent drop.
2. **Where do prompt parts come from?** The graph assembles its text from the identity block (node 88),
   the scene file, and the negative (node 79). Parts must therefore be written by whatever *creates* the
   run, not extracted after the fact. This PRD needs a parts contract with the generator — which is
   W1.1's Thinker. Sequence: cheap now, complete after W1.1.
3. **Do the existing blob columns get migrated or kept?** `image_candidates.quality_metrics` and
   `pipeline_runs.quality_metrics` hold real data of a narrower shape. Migrate into `assessments`, or
   leave and expose a view? *Lean: leave the columns, write new metrics to the normalized table, and
   backfill only if a query needs it.*
4. **Is `pipeline_steps.comfy_workflow_json` or `comfy_workflows/` authoritative?** Two copies of the
   graph exist. This PRD records the workflow **sha** per render either way, but the authority question
   should be closed rather than inherited.

---
Drift note (gherkin-specialist): record every deviation when translating this into `.feature` files.
Attribution is the deliverable: if a criterion can be satisfied while the one-query question still needs
a human to reconstruct the mapping, it is not satisfied.
