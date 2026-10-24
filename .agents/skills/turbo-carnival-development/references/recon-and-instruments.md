# Recon, instruments, and the GPU phase machine

Operational procedure for *measuring* this project and for *sequencing* GPU work.

## 1. Read the numbers out of Postgres — never infer them

Ops logs, cron output and memory describe *states*; the DB holds the *measurements*.
When asked where the project stands, query first.

The table and column names are **not** what you would guess, and guessing them costs
calls (there is no `scheduled_posts`, and no `captured_at`):

- `growth_snapshots` — `followers`, `taken_at` (**not** `captured_at`),
  `follower_reach`, `non_follower_reach`, `reach_total`, `profile_views`,
  `accounts_engaged`, `media_count`
- `scheduling_posts` (**not** `scheduled_posts`) — `status`
  (`posted`/`failed`/`scheduled`), `scheduled_at`, `reel_path`, `failure_reason`
- also `photos`, `personas`, `content_pillars`, `growth_goals`, `growth_decisions`,
  `growth_reviews`

```bash
psql -d turbo_carnival_development -c "select count(*) filter (where reel_path is not null) as reels, count(*) as total from scheduling_posts;"
psql -d turbo_carnival_development -c "select max(non_follower_reach), max(reach_total), max(profile_views) from growth_snapshots;"
psql -d turbo_carnival_development -c "select status, count(*) from scheduling_posts group by status;"
psql -d turbo_carnival_development -c "select left(coalesce(failure_reason,'?'),50) as err, count(*) from scheduling_posts where status='failed' group by 1 order by 2 desc;"
```

**Reels vs statics is the first cut to make.** An account's whole reach story is
visible in `reel_path is not null` plus the `non_follower_reach` series. Diff the
non-follower reach *before and after* a reel landed against a static-only window —
that comparison is the only thing that has ever shown a discovery effect here.

**Caveat:** `failure_reason` is frequently blank even on `failed` rows, so a failure
*count* understates nothing but explains nothing. Never report it as diagnosed.

## 2. Instrument rules

- **`non_follower_reach` is the primary instrument.** It is the only metric that
  measures discovery at all. Follower count is a *lagging* outcome.
- Measured: hundreds of static posts produced exactly **zero** non-follower reach,
  while the single published reel produced ~4x total reach and the account's only
  profile views. Static-first publishing is therefore **inert by construction** —
  captions, hashtags, pillar weights and cadence cannot move a number that is zero on
  a surface with no discovery step.
- **A tuning lever on a zero-discovery surface is theatre.** Before proposing any
  content or growth lever, ask whether it can move non-follower reach.
- Treat a small-n result (one reel, one week) as the strongest available *signal* and
  record it as a pre-registered hypothesis with an evaluation window — not as proof.
- Check render provenance on every accepted asset (`base_model`, `seed`, `prompt_hash`,
  `quality_metrics`).

## 3. The GPU phase machine (standing architecture)

The 4090 is shared and 24 GB cannot hold a text LLM and the render stack at once
(LTX-2.5 alone is a 22B transformer at int8 plus a 12B text encoder). So text and
render work **never co-reside** — work is sequenced:

```
THINK   llama.cpp up (uncensored) → brief, specs, cover-frame spec, captions
   ↓ stop server, VERIFY free VRAM ≥ floor                  [fail-closed]
RENDER  ComfyUI up — ONE scheduler claim covers the whole batch
   ↓ stop ComfyUI, release claim, verify port closed
JUDGE   llama.cpp up again → score each render vs brief → record verdicts
```

- **One claim covers the whole batch.** Yield the card between THINK and RENDER and
  you may never get it back.
- **Handoffs are READ, not assumed** — CUDA holds VRAM briefly after process exit, so
  free VRAM from `nvidia-smi` is the gate, not process exit alone.
- **Batch to amortise the swap**: all LLM work, then all renders, then all reviews.
- **"Batch refused, keep the trigger firing" is a normal state** on a co-tenanted card
  — the existing `vram_insufficient` path, generalised. Do not treat it as a fault.

### The four layers that must stay unfused

| Layer | What it is | Rule |
|---|---|---|
| Trigger | what makes work *wanted* | schedule / event / threshold → **emits** jobs |
| Job | typed work + contract (inputs, output schema, acceptance) | declarative data, not code |
| Role | who does it (prompt + model + tools + rubric) | thinker / generator / reviewer / director |
| Placement | where it runs (which GPU, which phase) | **policy, not topology** |

*Placement is policy* is what lets a second persona or venue be added as a config row
rather than a second system. Roles: the **thinker** owns an audience model and a
written hypothesis ledger and emits briefs; the **generator** turns a brief into an
explicit spec plus a named cover frame and must not grade its own output; the
**reviewer** applies two rubrics — does it land, and *will the platform distribute it*
— plus identity, realness and the legal floor.

## 4. Bound every NFS tree walk

The ComfyUI model store and render corpus are NFS-backed. An unbounded `find` over
`/mnt/nas-ai-models` or `/mnt/fscache/essdee` **times out**, and so does a plain `ls`
of a large ComfyUI workflow directory. Always pair with `timeout` and a tight maxdepth:

```bash
timeout 40 find /mnt/nas-ai-models -maxdepth 3 -iname '*ltx*' 2>/dev/null
```

To locate an asset, read the workflow JSON or `extra_model_paths.yaml` instead of
walking the tree — see `references/render-rails.md`.
