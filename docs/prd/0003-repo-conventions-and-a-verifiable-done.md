---
venture: turbo-carnival
source: PROJECT_PLAN
---

# PRD 0003 — Repo conventions, and a verifiable "done"

> **Status:** CURRENT · founder rulings incorporated 2026-10-19 · ready to cut tickets
> Plan item: **W1.3** · Track: `core-infrastructure` · Blocks: every agent working a ticket

## Summary

Give the repo the house conventions — a current `AGENTS.md`, a single Tier-0 gate (`bin/verify`), a CI
that actually exercises the real test suite, and a check that ties tickets to the plan — so that **"done"
is a state a machine can verify** instead of a claim an agent makes about itself.

## Founder rulings (2026-10-19)

These close the draft's open questions. They are recorded verbatim because they are decisions, not
preferences to be re-litigated by the next agent.

1. **OpenSpec is dropped, in favour of the PRD/ticket system.** *"drop it if it clears up things for
   future agents."* Removal is authorised.
2. **Style autocorrect is acceptable — but only once a working test suite is behind it.** *"autocorrect is
   fine with me once we have a working test suite."* Order matters: wire the suite first; autocorrect
   second. Until a suite is wired, a mechanical change must carry a human-readable diff justification.
3. **The test framework is rspec, not Minitest.** *"why minitest? we prefer rspec."* And use the
   house agent formatter rather than inventing one:
   `pi-216/t-genetics:lib/rspec/agent_formatter.rb` (+ its agent-aware `bin/rspec`).
4. **A clean packwerk is the goal of `bin/verify`.** Not "wired but tolerant" — clean.
5. **`plan:check` may be a rake task.** *"we need a running rails app anyway to serve assets to instagram
   through the cloudflare tunnel."* The app is not a cost to avoid, so a Rails-booting check is fine.

## Problem / motivation

Seven verified findings from an inventory on 2026-10-19. None are guesses; each has a file or a run behind it.

**1. The conventions document describes a process this project dropped.** `AGENTS.md` (21 lines) is the
**OpenSpec managed block**. Yet `config/autonomous/pipeline.yml` carries `agents_md: AGENTS.md` — so **the
board actively points agents at a dead process.** An agent picking up a ticket today reads instructions for
something we no longer use, and is told to open `openspec/AGENTS.md`.

**2. There is no `bin/verify`.** t-chat and crawlr both have one; turbo-carnival does not. `bin/` holds
`brakeman`, `rubocop`, `rspec`, `packwerk` — the *pieces* — but nothing that composes them into one
pass/fail answer. So an agent's definition of done is its own assertion, which is precisely the failure
the house conventions exist to prevent.

**3. A trivial offense reached `main`, because no local gate exists.** The push landing these PRDs
triggered CI at `2026-10-19T00:03:32Z` and it **failed** — as did all four dependabot PRs from the same
window. Cause, from the CI log and reproduced locally:

```
9  Style/StringLiterals [Safe Correctable]
9  Total in 1 files        -- lib/tasks/pipeline_workflows.rake
```

Nine single-quoted strings in **one newly added file**: an offense rubocop autofixes without judgement,
that a local `bin/verify` would have caught **before** the push. The lint step also runs **ahead of** the
test step, so a lint failure masks the test lane entirely. *(Resolved at `7126395`; recorded because the
absence of the local gate is the finding. This PRD does not claim CI had been red for a long time — the
one measured instance traces to a single file added the same day.)*

**4. CI's test lane is VACUOUS — it reports success while executing nothing.** This is the most serious
finding, and it is the precise failure this PRD exists to prevent, already present inside the pipeline.

```
CI test step : bin/rails db:test:prepare test        # Minitest, over test/
test/        : 15 .rb files, of which *_test.rb = 0  # no test files at all
local run    : 0 runs, 0 assertions, 0 failures, 0 errors, 0 skips   exit 0
```

So the lane cannot fail on a test regression, because it never executes an example — and it reports
**green**. Meanwhile the real suite is **rspec**: `spec/` holds **73** `*_spec.rb` files, `packs/*/spec`
holds **21** more, and one run executes **630 examples, 0 failures, 8 pending in 18.8 s** (measured, not
estimated). Two lanes exist; CI runs the empty one.

*Correction to the draft:* it said "`test/` (28 files)" and called that lane Minitest. There are **0**
Minitest files. This is the stock Rails 8 `ci.yml` template — nobody chose Minitest, it was never removed.

**5. Bounded contexts are not enforced where it counts, and they are not currently clean.**
`packwerk 3.2.3` is genuinely installed (confirmed in `Gemfile.lock`), with `packwerk.yml` and
`packs/*/package.yml` in place — but **CI never runs `packwerk check`**. Measured 2026-10-19:

```
bin/packwerk check -> 46 offenses detected, exit 1
  e.g. packs/scheduling/app/services/scheduling/failed_post_retry.rb:176
       ::Growth::Goal belongs to 'packs/growth_harness', but 'packs/scheduling' does not
       specify a dependency on 'packs/growth_harness'.
       (no stale violations detected)
```

A boundary that is only checked when someone remembers is not a boundary. Answering the draft's open
question: **packwerk is not clean today** — 46 real violations, so a clean packwerk is work, not a switch.

**6. The plan specifies a check that has no implementation.** `PROJECT_PLAN.md` §5 commits to
`plan:index` (generated from the board, never hand-typed) and `plan:check` (fails on an unknown plan id, a
dependency cycle, or a ticket In Progress whose `Depends on` is not Done). Neither exists. Right now the
plan's linkage contract is honoured by writing it down carefully and by nothing else.

**7. Nothing in the repo tells a future agent which document is current.** A prior pass stamped 23
documents with a status line (`CURRENT` / `REFERENCE` / `HISTORICAL` / `UNREVIEWED` / `SUPERSEDED`), but
five large root-level reports — `INTEGRATION_REPORT.md`, `INTEGRATION_ROADMAP.md`,
`PERSONA_INTEGRATION_SUMMARY.md`, `CATALYST_MIGRATION_SUMMARY.md`, `SESSION_NOTES.md` — carry no status,
specify a process we dropped, and are the kind of file an agent opens first because it is at the root.

## Goals / Non-goals

- **Goals**
  - One command, `bin/verify`, that a human and an agent both run, covering the repo's real test suite.
  - It **fails closed**: unable to run is never reported as passed, and **a lane that executes zero
    examples fails the build**.
  - **`main` is green**, and a deliberately broken change turns it red — verified in **both** directions.
  - `AGENTS.md` describes turbo-carnival, and every rule in it names how it is enforced.
  - The board's tickets are checkable against the plan, mechanically.
- **Non-goals (explicit Out)**
  - **Out:** any product behaviour change. This PRD adds gates, not features.
  - **Out:** `bin/publish_prd` — dropped by the founder, 2026-10-18. Tickets are cut against the plan.
  - **Out:** a BDD/Gherkin lane. See the red lines; adding one this repo will not run would recreate
    finding 4 in a new place.
  - **Out:** the Thinker, venue B, the render stack, the experiment DB.

## Scope — In / Out

**In:** `AGENTS.md` rewritten for this repo · port `lib/rspec/agent_formatter.rb` + agent-aware `bin/rspec`
from t-genetics · CI rewired to the rspec lane · `bin/verify` (Tier 0) · the 46 packwerk violations
resolved or individually baselined · `plan:index` / `plan:check` as rake tasks · deleting `openspec/` and
repointing `agents_md` · status-stamping or archiving the five unmarked root reports.

**Out:** prompt authoring, new pipelines, dashboards, anything in W1.1/W1.2.

## Acceptance criteria

```gherkin
Scenario: no lane can pass by executing nothing
  Given CI's test step is run against a suite with zero examples
  When the step completes
  Then the build FAILS
  # today this reports success -- finding 4; it is the defect, not the baseline

Scenario: CI runs the real suite
  Given a change that breaks one rspec example
  When CI runs on a pull request
  Then CI fails and names that example
  And main is green with the change reverted

Scenario: the agent formatter emits a machine verdict
  Given a run with 0 failures
  Then stdout is a single TESTS OK line and the full report exists on disk
  And given a run that loads nothing, stdout says TESTS ZERO, not OK
  # 0 examples and no-summary must never read as a pass

Scenario: an agent finds current conventions
  Given an agent opens the repository
  When it reads AGENTS.md
  Then it finds conventions for turbo-carnival, not a dropped process
  And each rule names how it is enforced
  And nothing in the repository points at OpenSpec

Scenario: the gate is not vacuous — proven in both directions
  Given a deliberately failing spec
  When bin/verify runs
  Then it exits non-zero and names the failing spec
  And after the spec is reverted it exits zero
  # a gate tested only in the passing direction is not tested

Scenario: the gate fails closed
  Given a dependency bin/verify needs is unavailable
  When bin/verify runs
  Then it reports failure and never success

Scenario: packwerk is enforced, not remembered
  Given a pack references another pack without declaring the dependency
  When CI runs
  Then the build fails

Scenario: tickets are checkable against the plan
  Given a ticket citing a plan id that does not exist
  When plan:check runs
  Then it fails
  And given a ticket In Progress whose Depends on is not Done, plan:check fails
```

## User stories / job-to-be-done

- As an **agent working a ticket**, I want a command that tells me whether I am done, so that "done" is not
  my own opinion.
- As the **founder**, I want main green, so that a red CI means something again — *and green to mean the
  suite ran*, which today it does not.
- As a **next agent**, I want `AGENTS.md` to describe this repo, so that I don't follow a process that was
  abandoned a month ago.
- As the **Director**, I want tickets tied to the plan mechanically, so that the board cannot drift from
  the plan without something noticing.

## Edge cases & red lines

- **A lane that executes zero examples must fail.** This is finding 4 and it is the house's Pipeline-Silence
  rule: a run that produced no signal is not a pass. An empty lane reported as green is worse than a missing
  lane, because it is actively trusted. Wire this into `bin/verify` **and** into CI.
- **A gate the repo does not run is worse than no gate.** It reads as coverage while providing none. If
  Gherkin is wanted here, it is its own decision and its own PRD, with the lane wired into `bin/verify` on
  day one.
- **Fail closed.** Missing tool, missing dependency, crashed process → failure, never success.
- **Green first.** You cannot trust a gate that has never been green. Making `main` green (or making a
  deliberate, recorded decision to relax a rule) is a prerequisite of this PRD, not a follow-up to it.
- **Autocorrect order.** Per ruling 2: the suite is wired **before** styles are autocorrected, and any
  mechanical change carries a diff a human can read. The `pipeline_workflows.rake` autocorrect already
  landed at `7126395` as 9 quote characters, verified by `ruby -c` and a whole-repo lint run — recorded
  here as the pattern, not as a precedent for future unattended autocorrect.
- **Do not port the whole of t-chat's `AGENTS.md`.** Much of it is t-chat's product. Port the rules that
  apply here — pack boundaries, command objects, factory truth, the PR gate — and say plainly which ones
  do not.
- **No silent rule disables.** If a rubocop rule is relaxed, the reason is recorded in the file next to it.
- **packwerk: no blanket disable.** The 46 violations are resolved or baselined **individually**, each with
  its reason. A repo-wide `exclude` would turn finding 5 into a permanently vacuous gate.
- Nothing here is destructive; removing `openspec/` is a `git rm` over **114 tracked files** (verified), so
  the history keeps it.

## Metrics / definition of done

- `main` green in CI; a seeded broken spec makes it **red**; reverting makes it green again.
- The test lane executes the **rspec** suite (630 examples) and **fails when it executes 0**.
- `bin/verify` exists, is named in `AGENTS.md`, and runs rspec plus the security, style and boundary gates.
- `bin/packwerk check` is **clean** (from 46 offenses).
- `plan:check` catches both a fabricated plan id and a dependency cycle, demonstrated then reverted.
- `AGENTS.md` no longer describes OpenSpec; `agents_md` in the pipeline config points at something true.
- `openspec/` is gone and nothing references it.

## Open questions

1. **packwerk's 46 violations — resolve, or baseline with a burn-down?** Ruling 4 says clean is the goal.
   The sub-question is whether all 46 are declared-dependency omissions (mechanical) or whether some reveal
   a real design error, in which case the ticket is larger and should be split. *Lean: triage all 46 first,
   then split into "declare the dependency" vs "the code is in the wrong pack".*
2. **Delete the empty `test/` directory?** It holds 15 non-test `.rb` files. Removing the CI step is
   certain; whether `test/` dies with it is cosmetic. *Lean: leave the directory, remove the lane, and let
   a later cleanup delete it once nothing references it.*
3. **How much of the five unmarked root reports is worth stamping versus archiving?** They are historical
   integration logs. *Lean: `git mv` into `docs/archive/` with one README, rather than stamping five large
   files that will still be opened by mistake because they sit at the root.*

---
Drift note (gherkin-specialist): record every deviation when translating this into `.feature` files. The
anti-vacuity scenarios are the ones that matter: a gate demonstrated only in its passing direction has not
been tested, and a lane that executes nothing must never report success.
