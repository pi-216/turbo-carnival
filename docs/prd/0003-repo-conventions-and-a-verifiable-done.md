---
venture: turbo-carnival
source: PROJECT_PLAN
---

# PRD 0003 — Repo conventions, and a verifiable "done"

> **Status:** CURRENT · draft for founder review · 2026-10-19
> Plan item: **W1.3** · Track: `core-infrastructure` · Blocks: every agent working a ticket

## Summary

Give the repo the house conventions — a current `AGENTS.md`, a single Tier-0 gate (`bin/verify`), a CI
that actually exercises the real test suite, and a check that ties tickets to the plan — so that **"done"
is a state a machine can verify** instead of a claim an agent makes about itself.

## Problem / motivation

Six verified findings from an inventory on 2026-10-19. None are guesses; each has a file or a run behind it.

**1. The conventions document describes a process this project dropped.** `AGENTS.md` (17 lines) is the
**OpenSpec managed block**. OpenSpec was dropped by the founder on 2026-09-17, and `docs/README.md`
now lists that file as **SUPERSEDED**. Yet `config/autonomous/pipeline.yml` carries
`agents_md: AGENTS.md` — so **the board actively points agents at a dead process.** An agent picking up
a ticket today reads instructions for something we no longer use.

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
that a local `bin/verify` would have caught **before** the push, and that instead surfaced only in CI. The
lint step also runs **ahead of** the test step, so a lint failure masks the test lane entirely.

*Scope note — this PRD does not claim CI has been red for a long time.* That was not verified, and the one
instance measured traces to a single file added the same day. **The finding is the absence of a local
gate, not a chronic condition.** Stating it as chronic would be exactly the kind of unearned claim this
repo's own rules forbid.

**4. CI does not run the repo's real tests.** The test step is
`bin/rails db:test:prepare test` — **Minitest**, over `test/` (28 files). The substantive suite is
**rspec**: `spec/` holds **73 `*_spec.rb`** files with `rspec-rails` and `factory_bot_rails` installed.
Two lanes exist; CI runs the smaller one. Even with lint green, none of the 73 specs would execute.

**5. Bounded contexts are not enforced where it counts.** `packwerk 3.2.3` is genuinely installed
(confirmed in `Gemfile.lock`), with `packwerk.yml` and `packs/*/package.yml` in place — but **CI never
runs `packwerk check`**. A boundary that is only checked when someone remembers is not a boundary; it is
a convention, and this PRD exists because conventions without enforcement decay.

**6. The plan specifies a check that has no implementation.** `PROJECT_PLAN.md` §5 commits to
`plan:index` (generated from the board, never hand-typed) and `plan:check` (fails on an unknown plan id, a
dependency cycle, or a ticket In Progress whose `Depends on` is not Done). Neither exists. Right now the
plan's linkage contract is honoured by writing it down carefully and by nothing else.

## Goals / Non-goals

- **Goals**
  - One command, `bin/verify`, that a human and an agent both run, covering the repo's real test suite.
  - It **fails closed**: unable to run is never reported as passed.
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

**In:** `AGENTS.md` rewritten for this repo · `bin/verify` (Tier 0) · CI rewired to run it — rspec,
packwerk, and the lint/security set · the lint reconciliation that makes green possible · `plan:index` /
`plan:check` · archiving OpenSpec and repointing `agents_md`.

**Out:** prompt authoring, new pipelines, dashboards, anything in W1.1/W1.2.

## Acceptance criteria

```gherkin
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

Scenario: CI runs the real suite
  Given a change that breaks one rspec example
  When CI runs on a pull request
  Then CI fails and names that example
  And main is green with the change reverted

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
- As the **founder**, I want main green, so that a red CI means something again.
- As a **next agent**, I want `AGENTS.md` to describe this repo, so that I don't follow a process that was
  abandoned a month ago.
- As the **Director**, I want tickets tied to the plan mechanically, so that the board cannot drift from
  the plan without something noticing.

## Edge cases & red lines

- **A gate the repo does not run is worse than no gate.** It reads as coverage while providing none. This
  is the finding-4 failure; do not recreate it elsewhere. If Gherkin is wanted here, it is its own
  decision and its own PRD, with the lane wired into `bin/verify` on day one.
- **Fail closed.** Missing tool, missing dependency, crashed process → failure, never success.
- **Green first.** You cannot trust a gate that has never been green. Making `main` green (or making a
  deliberate, recorded decision to relax a rule) is a prerequisite of this PRD, not a follow-up to it.
- **Do not port the whole of t-chat's `AGENTS.md`.** Much of it is t-chat's product. Port the rules that
  apply here — pack boundaries, command objects, factory truth, the PR gate — and say plainly which ones
  do not.
- **No silent rule disables.** If a rubocop rule is relaxed, the reason is recorded in the file next to it.
  A quiet exclusion is how the current red CI got normalised.
- Nothing here is destructive; archiving OpenSpec is a `git mv`, which keeps the history.

## Metrics / definition of done

- `main` green in CI; a seeded broken spec makes it **red**; reverting makes it green again.
- `bin/verify` exists, is named in `AGENTS.md`, and runs the repo's **rspec** suite plus the security and
  boundary gates.
- `plan:check` catches both a fabricated plan id and a dependency cycle, demonstrated then reverted.
- `AGENTS.md` no longer describes OpenSpec; `agents_md` in the pipeline config points at something true.
- OpenSpec is archived and nothing references it.

## Open questions

1. **Lint reconciliation: fix the code, or relax the rule?** The codebase is consistently
   single-quoted; `rubocop-rails-omakase` wants double quotes. `bin/rubocop -a` can autocorrect the whole
   tree mechanically. *Lean: autocorrect* — the rule is cosmetic, the default is the house style, and a
   recorded relaxation of a fresh Rails default invites drift. Either way it is a **recorded decision**,
   not a quiet exclusion.
2. **Two test lanes.** `test/` (Minitest, 28 files) and `spec/` (rspec, 73 files). Run both in
   `bin/verify`, or standardise on rspec? *Lean: run both initially* — do not delete a suite while
   wiring a gate; retire one deliberately later, with the counts to justify it.
3. **Is `packwerk check` clean today?** It is installed but unenforced, so nobody knows. Measure it and
   report before deciding whether this PRD fixes violations or records an exemption.
4. **Where does `plan:check` live** — a rake task (needs Rails booted) or a `bin/` script (does not)?
   *Lean: `bin/`*, so it runs in CI without booting the app.

---
Drift note (gherkin-specialist): record every deviation when translating this into `.feature` files. The
anti-vacuity scenario is the one that matters: a gate demonstrated only in its passing direction has not
been tested.
