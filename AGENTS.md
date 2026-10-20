# AGENTS.md — turbo-carnival

> **Status:** CURRENT — house conventions for this repo.
> Replaces the OpenSpec managed block, which the founder dropped on 2026-10-19 in favour of the
> PRD/ticket system. If you find a document telling you to run `openspec …`, it is stale — say so.

## What this repo is

A Rails 8 application that runs an autonomous Instagram growth harness for a **synthetic persona**,
plus the ComfyUI render pipeline behind it. Two venues: a discovery surface (Instagram), pushed to its
measured platform tolerance (PRD 0007 B4), and a permissive payload venue behind a second isolated
persona. Work is organised as **PRDs + GitHub tickets** on board `pi-216` project **#5**
(`https://github.com/orgs/pi-216/projects/5`).

## Read these, in this order

1. `docs/README.md` — the documentation index **and the status rules**. Start here.
2. `docs/PROJECT_PLAN.md` — the spine: workstreams, ordering, ticket linkage.
3. `docs/experiment-backlog.md` — the experiment lane's record: pre-registrations and verdicts.
4. `AGENTS.md` (this file) — who decides what (§ *the authority ladder*), and how each rule is enforced.

Every document carries a status line — `CURRENT` / `REFERENCE` / `HISTORICAL` / `UNREVIEWED` /
`SUPERSEDED`. **Only `CURRENT` is authoritative.** If two documents disagree and both say CURRENT, that is
a defect: fix one, don't average them. One truth per topic — never write a `v(N+1)` alongside the old one.

## Rules, and how each is enforced

A rule with no enforcement is a preference. Every rule below names what actually holds it.

| Rule | Enforced by |
|---|---|
| One variable per experiment, pre-registered before code | `docs/experiment-backlog.md` + the harness's leaf-diff assertion |
| An incomplete render set is **never** presented as a smaller N | `scripts/replicate_pairs.py` refuses to build sheets from an incomplete manifest |
| Never commit secrets; scan before any push | manual scan for `sk-…`/`gho_…`/`EA…`/`AIza…`/PRIVATE KEY before pushing |
| Report only what a read-back proves | house rule: `Acknowledgment ≠ Resolution`, `Completion Status ≠ Completion Evidence` |
| ComfyUI runs only while this repo holds a GPU claim | `bin/comfyui_harness.sh` — **never** launch ComfyUI any other way |
| Style is house style | `bin/rubocop` (rubocop-rails-omakase) — **in CI** |
| No known security vulnerability ships | `bin/brakeman --no-pager` — **in CI** |
| Pack boundaries | `bin/packwerk check` — **0 violations** (29 declared, 12 baselined individually in `packs/*/package_todo.yml` — stale entries fail the check); run by `bin/verify` **in CI** (PRD 0003) |
| The real test suite | `bin/rspec` — **run in CI** with the agent test-signal verdict gate (a 0-example run fails the lane); also run by `bin/verify` (PRD 0003). The signal's own contract is gated by `bin/test-agent-signal` (§ *the agent test signal*) |
| Ticket linkage to the plan | intended `plan:check` — **does not exist yet** (PRD 0003) |

## The gate

`bin/verify` is the single Tier-0 gate (PRD 0003). It composes the existing entry points in a fixed
order and stops at the first failure:

```bash
cd /home/tim/source/activity/turbo-carnival
source /usr/share/rvm/scripts/rvm && rvm use 3.4.5
bin/verify          # rubocop -> brakeman -> bundler-audit -> packwerk -> erb_lint -> rspec
```

Fail-closed: a gate that cannot run (missing gem, DB down, 0 examples) is a failure, never a pass —
the rspec gate requires exit 0 **and** a `TESTS OK` verdict, not just the exit code. CI runs it as
the `verify` job; a green "done" claim requires it.

## The agent test signal

Test runs are fired by **unobserved** cron agents: no terminal, no redirect, and the agent's captured
stdout *is* its context window. A default rspec run prefills that window with kilobytes of progress
dots, application banners and framework backtrace it must read but cannot act on, so this repo owns
its test entry point.

- **The artifacts are ported, never hand-authored.** `bin/rspec`, `lib/rspec/agent_formatter.rb` and
  `bin/test-agent-signal` are **byte-identical** to `rails-venture-template` at merge commit
  `8dc4586b941a` (that repo's PR #9). Keep it that way: a repo-local variant breaks the fleet-wide
  parity check that makes one contract meaningful across ventures. Verify with
  `git show 8dc4586b941a:bin/rspec | diff - bin/rspec`.
- **Two modes, selected by TTY.** On a TTY with `AGENT_TEST` unset, `bin/rspec` hands over to real
  rspec untouched — a developer's terminal output does not move. With no TTY, or with `AGENT_TEST=1`,
  it prints a compact verdict to stdout and writes the complete, untruncated report to
  `~/.pi216/agent-test/<repo>-latest.log`, printing that path to stderr. `bundle exec rspec` stays
  available for anyone who wants the gem binstub.
- **Verdict vocabulary** (stable — agents grep for these prefixes): `TESTS OK` · `TESTS RED` (with the
  diff) · `TESTS ZERO` (0 examples ran — **not** a pass) · `TESTS UNKNOWN` (aborted, no summary — not
  a pass). `OK` can never be produced by silence, which is why both `bin/verify` and the CI test lane
  require the `TESTS OK` line and not merely exit 0.
- **The signal is a lens, never a replacement.** Anything the compact view caps is in the full log.
- **`bin/test-agent-signal` gates the mechanism, not the artifact.** It runs the formatter against
  synthetic ok/red/zero/load-error suites and asserts all 12 contract checks; it runs in CI. Change
  the formatter and it fails here rather than silently in a cron log nobody reads.
- **Application output must not share the verdict channel.** The formatter owns only what RSpec
  emits; rake task bodies print their banners with `puts` straight to the process's `$stdout`, and
  Sidekiq's logger writes its connection line there too. `spec/support/agent_test_quiet.rb` therefore
  reroutes application stdout to `tmp/agent-test/app-output.log` **while `AGENT_TEST=1`** (also
  uploaded as a CI artifact) and leaves the TTY path alone. `Rails.logger` is untouched — it
  broadcasts to `log/test.log` and never reached stdout. Measured on a green 830-example run,
  before/after: **6,800 B → 59 B**, one line.

`bin/rails test` remains callable and still runs `test/`, which holds zero test files — it is not the
signal and not the suite (§ *traps*).

## Traps that have actually cost time here

- **Do not trust CI's test lane.** It runs `bin/rails test` over `test/`, which contains **zero** test
  files — it executes nothing and reports success. The real suite is **rspec** (630 examples). This is
  finding 4 of PRD 0003. Verify with `bin/rspec`, not with a green check.
- **A failed create must never be reported as a no-op.** A script that says "already existed" when the
  thing does not exist has lied about delivered work. Print the failure.
- **Fingerprint, don't timestamp.** A crash in a shared log window is not yours until the graph's node
  fingerprint matches. This cost a killed experiment run once.
- **`--input -` is required** for `gh api` to read a body from stdin; without it the body is dropped
  silently and GitHub returns a misleading `422 links/0/schema`. See
  `skills/…/references/github-board-api.md`.
- **The pipeline is not deterministic.** Two identical renders differ by ~4/255 over ~5% of the frame. An
  axis must clear ≳4–6 levels over ~5% of the frame to be rankable at all.
- **The mask guard's protection is its polarity.** `LazySwitchKJ` fires `on_true` when the mask is
  non-empty ⇒ `on_true` must go to the **inpainted** branch, `on_false` to the **raw** one. Inverted, it
  fails twice: it crashes on the exact case it exists to prevent, and silently discards inpainting on all
  others.

## Working a ticket

1. The ticket **is** the job; the board **is** the queue and the audit trail.
2. Claims are made by flipping the board status **and** the labels in `config/autonomous/pipeline.yml` —
   `approved` (an agent may start), `agent_working`, `agent_blocked`, `agent_needs_review`, and
   `founder_needed` (only the founder can: a ruling, a credential, a platform setting, a GPU policy, or a
   physical action). **Never overload `approved` and `founder_needed`.**
3. **An agent may not set `approved`.** That label is the product owner's gate; a script that sets it has
   removed the gate.
4. Nothing is destructive without the founder's explicit confirmation. Archive, don't delete. Export
   before prune.

## Where work lives

| kind | where | rule |
|---|---|---|
| production code | `packs/*` (packwerk boundaries), `app/`, `lib/tasks/` | the daily flow lives here |
| **an experiment** | `experiments/<PRD-number>-<slug>/` | its own PRD, its own designated researcher, its own code, configs, decoder and verdict. **Removing the folder must not change production behaviour** |
| shared experiment machinery (the lane) | promoted out of `experiments/` into `scripts/` or `lib/` | only once **two** experiments need the same thing — never copied |
| the plan | `docs/PROJECT_PLAN.md` | the spine: workstreams, ordering, linkage contract |
| which doc is truth | `docs/README.md` | the index. Anything unlisted is not truth |

**Experiments are on the side, by one rule: the day-to-day flow does not depend on an experiment.** An
experiment may read production's outputs; production may never wait on an experiment. If deleting an
experiment changes how the daily flow behaves, the experiment has leaked — that is a defect.

## Who decides what — the authority ladder

Autonomy scales **inversely with the severity of the downside**. This table is the single source for the
authority boundary (it previously lived in `strategy-v3.md`, deleted 2026-10-19).

| class | example | who decides |
|---|---|---|
| 1 — correctness / quality | anatomy: four limbs, exactly one hand | **the system acts** |
| 2 — style / format / pillar | a new scene type, a new LoRA, a new base model, **or the content-pillar set itself** (reweight, retire, replace, rename, split, add) | **the system acts**, measured |
| 3 — explicitness / intensity | visible areola (nipples) and beyond, up to the measured platform boundary | **the system acts, measured** — bounded by the legal floor (PRD 0007 §1); an intensity step that crosses the floor is the floor's business, not class 3's |
| 4 — identity / persona | the age read, persona identity | **founder ruling** (unchanged: Sarah, 18) |

**Class 3 is delegated with a tier pre-flight (PRD 0007 A5, founder ruling 2026-10-20).** The delegation
is not blind, and it is not a standing per-post approval either. Before the intensity experiment pushes
the primary account past a tier, the founder verifies that tier: the system prepares it (renders, scores,
queues), presents the tier's assets + gate readings (NSFW score, aesthetic/sharpness, age band) for
review, and publishes from that tier only after the founder's go. Once a tier is validated, posting within
it proceeds autonomously — measured, bounded by the floor, revert on failure. The gate is on the tier
start, not on evidence: promotion still happens automatically on pre-registered thresholds, and nothing
parks between tiers.

**The content-pillar set is not a founder rail — it is class 2.** Founder ruling, 2026-10-19: *"the brain
or experimenter should know that the existing pillars are fair game."* The five rails in `THESIS.md`
(identity anchor, attribution spine, safety gates, decision ledger, reflection) stay locked; the **content
pillars** — which mix of topics Sarah posts — are a lever like any other, and the brain and the experimenter
may reweight, retire, replace, rename, split or add one. Enforcement: a change to a pillar's
`weight`/`priority`/`active` goes through the same bounded, reversible path as every other class-2 change
(`Growth::PersonaEvolution` — a single-step delta, a pre-registered gate, automatic revert on failure), so
"fair game" can never mean an unrecorded edit. **Retiring, replacing, renaming, splitting or adding a pillar
is permitted by this ruling but has no mechanism yet** — `PersonaEvolution` writes only those three fields —
so it is a ticket, not an edit to make by hand. What a pillar *depicts* is unchanged by this: intensity is
class 3, the age read is class 4.

**How this reconciles with "the founder is never a gate".** Two statements that look contradictory and are
not, because they are about different things:

- **The founder is not a gate on evidence.** Promotion happens automatically on a pre-registered threshold;
  the founder never approves a *design*, and no experiment waits on an approval.
- **The founder is the authority on class 4 (identity).** That is a ruling, not a measurement, and no
  amount of evidence produces one. Class 3 is no longer parked with the founder: the system acts,
  measured, inside the floor — the founder's role there is the tier pre-flight above, a deliberate safety
  action on tier starts, not an evidence gate.

**A withheld instrument parks safely; a withheld ruling fails closed — and there is no class-3 ruling
left to withhold.** Class 1–3 work continues; a class-4 question stops until it is answered, and the tier
pre-flight holds a row until the founder verifies the tier — a deliberate safety action (a held row), not
a defect. A floor question (a render reads minor, an asset lacks the mark) still fails closed. This is
the line the next agent reads first, and it is the reason PRD 0007 exists: **the docs must not leave an
uncensored model a plausible story for being timid.**

**Enforcement: the boundary must be mechanical, not a prompt instruction.** An agent free to not-hedge will
also rationalise self-authorizing a tier advance — the trait that makes it useful is the trait that makes
self-gating unsafe. A script refuses the self-grant: a tier is not validated by the system's say-so (the
pre-flight hold is a held row, and the floor gates run on the bytes), and class 4 never moves without the
founder. The model decides freely inside classes 1–3 within a validated tier.

> *"I am hoping that this can be an 'autonomous' content creator… I am a tool or consultant in this. not the
> blocker or approver or creator."* — founder, 2026-10-18

## The one hard gate

Everything else here is a **control** — an instrument that ranks, measures and informs. Exactly one thing
is a gate: the **legal floor**. Adult (18+), no real-person likeness, synthetic mark embedded. An agent may
not promote its own safety preference into a founder red line — that mistake has already happened once in this
repo's history, and the rule exists because of it.
