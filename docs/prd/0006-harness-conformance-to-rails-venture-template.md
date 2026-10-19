---
venture: turbo-carnival
source: PROJECT_PLAN
---

# PRD 0006 — Harness conformance to `rails-venture-template`

> **Status:** CURRENT · parity audit measured 2026-10-19 · **founder rulings Q1–Q6 landed 2026-10-19** ·
> ready to cut tickets
> Plan item: **W1.4** · Track: `core-infrastructure` · Blocks: nothing technically · blocks **every agent
> that works a ticket** if the rails are wrong

## Summary

turbo-carnival is the one pi-216 venture that **was not scaffolded from the founders-harness template**
(`pi-216/rails-venture-template`). It grew its own shape. That shape is close in places — packwerk packs,
`gl_command`, ViewComponent, Tailwind, a live Turbo morph trigger — and empty in others: **no `bin/verify`,
no `app/commands/application_command.rb`, no Sentry initialiser, no `FOUNDERS.md`, no PR template**. This
PRD runs the template's **parity audit**, records every rail as *conform* / *gap* / *deliberate deviation*,
and files the gaps as conforming work — so turbo-carnival is on the same harness as the rest of the fleet
and the fleet stays uniform.

## Founder rulings (2026-10-19)

These close the questions this PRD opened. Recorded verbatim — decisions, not preferences to re-litigate.

**Q1 — HAML.** *"we want to transition. We can prioritize later."* → **Adopt HAML**, as a **transition that
is explicitly deprioritised**: it lands as its own ticket and is a prerequisite for nothing. ERB stays
until the conversion lands; new views may be HAML.

**Q2 — Gherkin.** *"We want Gherkin for the web application. This application is not a standard rails
application, there are a lot of other tools involved. Many PRDs describe their behavior in Gherkin tests,
but they can't be tested in Ruby that way. I want to make sure that future agents understand that we like
Gherkin notation for definitions, but the ruby gherkin tests are only required to test the rails
application itself."*

→ **The two-layer rule — now this repo's convention, and it must be documented where agents read it:**

- **Layer 1 — Gherkin as notation (definitions).** House-wide. Every PRD describes behaviour in Gherkin
  *notation*, whatever implements it: the Rails app, the Python/ComfyUI render pipeline, the shell
  harness, the cron jobs. A definition is not a test.
- **Layer 2 — Gherkin as executable tests (Ruby/Cucumber).** Required for **the Rails application
  only** — its HTTP surface, its UI, its commands. Behaviour implemented by any other tool is defined in
  Gherkin and is **not** required to have an executable Ruby Gherkin test; it is tested by that tooling's
  own suite.

The trap this rule exists to prevent: a future agent reading a render-pipeline scenario in a PRD and trying
to *execute* it in Ruby. The lane that ships here is scoped to the Rails app, and the scoping is written
down, not assumed.

**Q3 — Sentry DSN.** *"there is a Sentry token available. You (an agent via a ticket) can provision it."*
→ **Not `founder_needed`.** The credential already exists; an agent provisions it through a ticket. This
removes the only blocker that would have parked rail R7, so the observability rail is now ordinary work.

**Q4 — documentation homes.** *"we need to adopt."* → **Adopt the template's homes** — `FOUNDERS.md`,
`ARCHITECTURE.md`, `CONTRACTS.md`, `OPS.md`, `DESIGN.md`, `.github/pull_request_template.md`,
`docs/prd/README.md`, `docs/tech_design_docs/`, `packs/README.md` — and reconcile the repo's existing
`docs/` documents into them under the one-truth-per-topic rule (never a new `v(N+1)` beside an old file).

**Q5 — job substrate.** *"we want to transition to sidekiq."* → **Sidekiq is the single substrate.**
`solid_queue` / `solid_cache` / `solid_cable` are retired in favour of Sidekiq (+ Redis); the transition is
a ticket, and **no new work may be added on the `solid_*` substrate**.

**Q6 — scope.** *"This is a new, independent PRD."* → PRD 0006 **stands alone** at W1.4; it is not folded
into PRD 0003.

**Q7 — `aasm` vs `state_machines`.** *"state_machines over aasm"* → **`state_machines-activerecord` is
ratified** as this repo's state-machine library; `aasm` is **not** adopted. The template pins `aasm` and this
repo does not — recorded as a deviation, not a gap.

**Q9 — where the non-Rails Gherkin definitions live.** *"They stay inline in the PRD; only Rails-app
scenarios become .feature files."* → **Layer-1 definitions live in the PRD, permanently.** Only Rails-app
scenarios are ever extracted into `.feature` files. There is no `gherkin_specs/` home for behaviour the Rails
app does not implement — no `@non-executable` tree — and this PRD implies no future non-Ruby runner.

## What the harness is, and the one rule that shapes this PRD

`rails-venture-template` is a **single self-contained `template.rb`** that locks the Day-1 rails for a new
pi-216 venture. Its own README is explicit about the boundary: **the template is a snapshot, not a sync.**
It copies decisions *at scaffold time* for the **next** venture; existing ventures are its *source*, never
re-scaffolded. So this PRD is **not** "run `template.rb` against turbo-carnival." It is a **parity audit →
tickets** (the `cross-repo-venture-rollout` mechanism): read the template, measure this repo against each
rail, and apply the differences **file-by-file**, byte-identically for anything the fleet must share.

The rails, from `template.rb` and the README "What it locks" table:

| # | rail | what it locks |
|---|---|---|
| R1 | Boring stack | Rails 8 + pg + Puma + importmap + Turbo/Stimulus + HAML + ViewComponent + Tailwind |
| R2 | Turbo liveness | HEAD `<meta name="turbo-refresh-method" content="morph">` (**trigger**) + `<body data-turbo-morph>` (**marker**) + importmap/Stimulus wiring |
| R3 | Command rail | `gl_command` + `ApplicationCommand < GLCommand::Callable` with `run_after_commit` |
| R4 | Bounded contexts | packwerk + `packs/*` autoload wiring in `config/application.rb` |
| R5 | BDD pipeline | Cucumber + `gherkin_specs/` + `.gherkin_lint.yml` + `config/cucumber.yml` |
| R6 | Quality gates | `bin/verify` = rubocop · brakeman · bundler-audit · packwerk · erb_lint · rspec · cucumber · gherkin_lint · rswag |
| R7 | Observability | Sentry initialiser, DSN in encrypted credentials, Team-plan surface incl. `Sentry::Metrics` |
| R8 | Governance | AGENTS.md content contract · `THESIS.md` + `FOUNDERS.md` · PR template · `docs/prd/README.md` · `docs/tech_design_docs/` · single lint entry point |
| R9 | rswag | swagger generation + verify — activates only when `swagger/` exists |

## Problem / motivation

Ten findings from a parity audit on **2026-10-19**. Each has a file or a run behind it — none is a guess.
The audit is the artifact; the findings are its result.

**F1 — The command rail is a documented contract with zero implementation.** `AGENTS.md` mandates
"side effects … scheduled **after commit**", and every command in the repo subclasses `GLCommand::Callable`
(the template's `ApplicationCommand` ancestor) — but **`app/commands/application_command.rb` does not
exist**:

```
$ ls app/commands/application_command.rb        → No such file or directory
$ grep -rn "< GLCommand\|ApplicationCommand" app/commands/
app/commands/post_automation/create_scheduled_post.rb:5:  class CreateScheduledPost < GLCommand::Callable
app/commands/post_automation/auto_create_next_post.rb:5:  class AutoCreateNextPost < GLCommand::Chainable
…
```

There is no `run_after_commit` helper anywhere, so the rule is honoured by luck or not at all. This is the
template parity audit's named recurring gap.

**F2 — Sentry is installed and emits nothing.** There is **no `config/initializers/sentry.rb`** and **no
`Sentry` reference anywhere in `config/`, `app/`, `lib/` or `packs/`**:

```
$ ls config/initializers/sentry.rb              → No such file or directory
$ grep -rn "Sentry" config/ app/ lib/ packs/    → (no output)
```

The gems nonetheless resolve — `sentry-rails (7.1.0)`, `sentry-ruby`, `sentry-sidekiq` — because
`gl_command` depends on `gl_exception_notifier`, which depends on them (`Gemfile.lock:190-193`). So the
venture has **error capture, releases, cron check-ins and custom metrics all available and all switched
off**. Per the harness, *a missing DSN is a finding, not a neutral state* — and turbo-carnival is the only
fleet repo that emits nothing.

**F3 — No `bin/verify`, and the pieces it would compose are partly absent.** `bin/` holds `rubocop`,
`brakeman`, `rspec`, `packwerk` — the *parts* — but nothing that composes them. Two of the template's gate
members are **not installed at all**:

```
$ for g in bundler-audit erb_lint strong_migrations; do grep -q "^    $g " Gemfile.lock || echo "ABSENT: $g"; done
ABSENT: bundler-audit
ABSENT: erb_lint
ABSENT: strong_migrations
```

(`bin/verify` itself is **PRD 0003 / ticket #47** — this PRD owns only the *gate membership* the template
names and this repo lacks: `bundler-audit`, `erb_lint`, and the packwerk step PRD 0003 already covers.)

**F4 — CI is a subset of the gate, and one lane is vacuous.** `.github/workflows/ci.yml` runs **brakeman
only** for security (no `bundler-audit`), **rubocop only** for lint (no `packwerk`, no `erb_lint`), and a
**test lane that executes nothing**:

```
- name: Run tests
  run: bin/rails db:test:prepare test      # Minitest over test/ — 0 test files, reports green
```

The template's CI runs `bundler-audit`, `brakeman`, `bin/importmap audit`, `packwerk check`, `erb_lint`,
then `bin/rspec` + `bin/test-agent-signal`. Turbo-carnival's CI is a thin slice of that, and the slice that
is present lies. *(F4's vacuous-lane half is **PRD 0003 / ticket #45**; this PRD owns the missing scan
jobs.)*

**F5 — The agent test-signal layer is absent, and already ticketed.** `bin/rspec` is the **stock 3-line
bundler binstub**, and there is no `lib/rspec/agent_formatter.rb` and no `bin/test-agent-signal`:

```
$ cat bin/rspec
#!/usr/bin/env ruby
require "bundler/setup"
load Gem.bin_path("rspec-core", "rspec")
```

This is **issue #19**, opened against the template's PR #9 and scoped deliberately narrow. **This PRD
references it and does not duplicate it** — #19 is the test-signal rail's ticket.

**F6 — Governance stubs are missing.** The template writes and the repo lacks:

```
FOUNDERS.md                        → absent
.github/pull_request_template.md   → absent
docs/prd/README.md                 → absent
docs/tech_design_docs/             → absent
packs/README.md                    → absent
```

`AGENTS.md` itself is already rewritten for this repo (**PRD 0003**), so the *hub* conforms; its
**pillar index (`FOUNDERS.md`), its PR gate (`.github/pull_request_template.md`, the
`pr-conventions-gate` skill) and its docs surfaces** do not exist.

**F7 — `THESIS.md` exists but is inert, so there is no live thesis pillar.** The file is stamped
**HISTORICAL**, its content-strategy section is superseded by `docs/strategy-v2.md`, and *its one red line
was withdrawn 2026-10-18 because an agent, not the founder, authored it*. The template requires `THESIS.md`
to carry a literal **"We will NOT"** list that **every PRD cites**. Today nothing cites it, and the repo's
red lines live only inside PRD 0003's edge cases and `AGENTS.md`'s "one hard gate".

**F8 — Two rails are deliberately deviated, and the deviation is unwritten.** The template locks **HAML**
and a **Cucumber/Gherkin lane**. Turbo-carnival uses **ERB** (`app/views/layouts/application.html.erb`,
`views/gap_analyses/*.html.tailwindcss_spec.rb`) and has **no `gherkin_specs/`, no `config/cucumber.yml`,
no `.gherkin_lint.yml`, and no cucumber/gherkin_lint gems**. PRD 0003 already declares the Gherkin lane
**out** ("adding one this repo will not run would recreate finding 4 in a new place"), but the template
lists it as a locked rail — so the house and this repo disagree **in writing nowhere**. An unwritten
deviation is drift.

**F9 — `config/application.rb` does not use the template's pack wiring.** The repo loads packs through the
**`packs-rails`** gem; the template emits an explicit `Dir[Rails.root.join("packs/*/app/*")]` autoload
block anchored after `load_defaults`. The repo has **`packwerk.yml`, `package.yml` and 12 packs with
`package.yml` each**, and **47 offenses** (up from the 46 in PRD 0003 — the count moves as code lands):

```
$ bundle exec packwerk check   → 47 offenses detected · No stale violations detected
```

*(Zeroing the offenses is **PRD 0003 / ticket #46**; this PRD owns only whether the wiring rail is
satisfied — it is, by `packs-rails`, a superset.)*

**F10 — Turbo is live, but the marker is missing and the rail's gate must not assert the wrong thing.**
The **trigger** is present — `app/views/layouts/application.html.erb:6` carries
`<meta name="turbo-refresh-method" content="morph">` and `:15` carries `javascript_importmap_tags`;
`config/importmap.rb` pins Stimulus and `app/javascript/controllers/` holds five controllers. The
**marker** `<body data-turbo-morph>` is **absent**, and the template's own `AGENTS.md` records why that must
be treated carefully: *gate the mechanism (the head meta), never the artifact (the body marker)* — the
template shipped the marker without the trigger once (its issue #1).

## Goals / Non-goals

- **Goals**
  - A **written parity audit** of turbo-carnival against the template's nine rails, with every rail marked
    *conform* / *gap* / *deliberate deviation* — the artifact this PRD produces.
  - The **gaps closed**: the command base, the Sentry pillar, the missing gate members, the governance
    stubs, the Turbo marker.
  - The **deviations ratified**, each with a recorded reason (HAML, Gherkin, `packs-rails` wiring,
    `state_machines` vs `aasm`), never left implicit.
  - After this PRD: **a template parity audit of turbo-carnival returns only ratified deviations** — an
    empty findings list plus a deviations table that reads as intentional.
- **Non-goals (explicit Out)**
  - **Out:** re-scaffolding. The template is a snapshot; this repo is never `rails app:template`-ed.
  - **Out:** `bin/verify`, the vacuous test lane, and the `plan:check` machinery — **PRD 0003** owns them.
  - **Out:** the agent test-signal port (`bin/rspec` / `lib/rspec/agent_formatter.rb` /
    `bin/test-agent-signal`) — **issue #19** owns it.
  - **Out:** zeroing packwerk's 47 offenses — **PRD 0003 / #46**.
  - **Out:** any product behaviour change. This PRD adds rails, not features.

## Scope — In / Out

**In:** `app/commands/application_command.rb` (ported, byte-identical) + reparenting the command classes ·
`config/initializers/sentry.rb` (ported) + the DSN (founder-supplied) + the numeric-goal metrics ·
`bundler-audit`, `erb_lint`, `strong_migrations` gems + their gate/CI steps · `FOUNDERS.md` ·
`.github/pull_request_template.md` · `docs/prd/README.md` · `docs/tech_design_docs/` · `packs/README.md` ·
a live `THESIS.md` (or an explicitly recorded decision to keep the thesis in `strategy-v2.md`) · the Turbo
`<body data-turbo-morph>` marker · the deviations table.

**Out:** CI rewire (PRD 0003), test-signal (issue #19), packwerk offenses (PRD 0003), HAML conversion and
Gherkin adoption **until Q1/Q2 are ruled**.

## Boundary — what makes this PRD not a duplicate

Three documents now touch "conventions". The split is deliberate and stated so no future agent averages
them:

| Concern | Owner | Not this PRD |
|---|---|---|
| `AGENTS.md` rewritten for this repo; `bin/verify`; CI runs the **real** suite; `plan:index`/`plan:check`; packwerk → 0 | **PRD 0003** (epic #44, tickets #45–#50) | — |
| `bin/rspec` + `AgentFormatter` + `bin/test-agent-signal`, byte-identical to the template | **Issue #19** | — |
| **The rest of the template's nine rails**, the parity audit, and the ratification of deviations | **PRD 0006** (this) | PRD 0003, #19 |

Tickets cut from this PRD must cite PRD 0003 or #19 explicitly when a step belongs to them, rather than
re-cutting existing work.

## Acceptance criteria

```gherkin
Scenario: the command rail has an implementation, not just a sentence
  Given a command that schedules a side effect
  When it is called inside an open transaction
  Then the side effect runs only after the transaction commits
  And every command in app/commands and packs/*/app/commands subclasses ApplicationCommand
  # today: no app/commands/application_command.rb, no run_after_commit anywhere -- finding F1

Scenario: the parity audit is reproducible, not asserted
  Given the audit script is run against the repo
  When it completes
  Then it prints one line per template rail: CONFORM, GAP, or DEVIATION(reason)
  And it exits non-zero while any rail reads GAP
  # a parity claim with no run behind it is the failure mode this repo already names

Scenario: Sentry is live, and a numeric goal is tracked
  Given a DSN is present in encrypted credentials
  When an exception is raised in a configured environment
  Then an event is captured
  And the charter metric is emitted, not merely stored
  # Sentry::Metrics gauge for followers + required/day; count for pipeline acceptance
  # a numeric DoD line with no emitted telemetry is untracked (harness DoD-to-gate rule)

Scenario: Sentry stays silent in dev and test
  Given no DSN, or an unconfigured environment
  When the app boots
  Then no event is emitted and the boot is not slowed
  # enabled_environments = staging, production

Scenario: a gate the repo runs is a gate the repo has
  Given bin/verify lists bundler-audit and erb_lint
  When a known-vulnerable gem is present, or an ERB template is unlintable
  Then the build FAILS
  # today those gems are not installed at all -- finding F3

Scenario: the Turbo rail asserts the trigger, not the marker
  Given the layout's HEAD
  Then it carries <meta name="turbo-refresh-method" content="morph">
  And the spec asserts THAT, not <body data-turbo-morph>
  # the body attribute is inert; the meta is what Turbo reads (template issue #1)

Scenario: every deviation is written down
  Given HAML, Cucumber, packs-rails wiring and state_machines
  Then each appears in the deviations table with a reason and a ruling reference
  And no rail is left "missing" without a disposition

Scenario: the thesis pillar is live
  Given FOUNDERS.md exists
  Then each pillar names Lock / Enforcement / Red line
  And THESIS.md carries a current "We will NOT" list, or the recorded decision to keep it elsewhere
```

## User stories / job-to-be-done

- As **the Director**, I want every pi-216 venture on one harness, so that a parity audit returns
  deviations-by-choice, not gaps-by-accident.
- As an **agent working a ticket**, I want `ApplicationCommand` and a Sentry initialiser to exist, so I
  follow a contract that is implemented rather than described.
- As a **future agent onboarding to this repo**, I want a deviations table, so I do not "fix" a deliberate
  choice — or re-litigate HAML.
- As the **founder**, I want the charter's number tracked where the fleet tracks numbers, so a stall is an
  alert rather than a review someone remembers to read.

## Edge cases & red lines

- **The template is a snapshot, not a sync.** Never re-scaffold. Port **file-by-file**, and for anything
  the fleet shares (`bin/rspec`, `lib/rspec/agent_formatter.rb`, `bin/test-agent-signal`,
  `application_command.rb`, `sentry.rb`) copy from a **pinned merged commit** and prove **byte-identity**
  (`diff <(git show <sha>:<path>) <path>`). A hand-authored variant forks an artifact that must be uniform.
- **Gate the mechanism, never the marker.** Turbo is the canonical case: assert the head `meta`, not the
  body attribute — the body attribute is documentation no Turbo version reads.
- **No rail without its enforcement line.** Adopting a template rail means adopting what holds it (a CI
  job, a `bin/verify` member, a spec). An unenforced pillar rots.
- **A gate the repo does not run is worse than no gate.** Q2 ruled **adopt**, so the Cucumber lane is
  wired into `bin/verify` **on day one** — `gherkin_lint` with it. A lane adopted half-way reads as
  coverage while providing none.
- **Written or it drifts.** Every deviation gets a row: rail · template requires · this repo does · why ·
  ruling. An unwritten deviation is the drift this PRD exists to remove.
- **Secrets only in encrypted credentials — and the Sentry DSN is now agent work.** The DSN lives in
  encrypted credentials, never in the repo or in env; the token **already exists** (Q3), so an agent
  provisions it through a ticket instead of parking the rail for the founder. "No DSN yet" is still a
  **finding**, not a pass.
- **Gherkin has two layers; do not collapse them (Q2).** Layer 1 (notation, in PRDs) is house-wide and
  non-executable. Layer 2 (Cucumber) is required for the **Rails application only**. Never try to execute a
  non-Rails scenario in Ruby — and conversely, "no executable test" never means "not defined".
- **One job substrate (Q5).** No new work on `solid_*`; Sidekiq (+ Redis) is the target, and the migration
  is its own ticket — not a rewrite in passing.
- **`AGENTS.md` is a protected agent-instruction file.** Any write to it needs explicit operator approval;
  a timed-out consent prompt is not consent — keep the code committed, leave the doc out, surface it.
- **Do not port `t-chat`'s or `crawlr`'s `AGENTS.md` wholesale.** Port the rules that apply and say which
  do not.
- **Fail closed; green first.** A rail adopted into a red gate is not adopted.
- **Class 3–4 stays the founder's.** Nothing here is a persona, intensity or identity change; if a step
  ever looks like one, it stops and files a ruling.

## The parity audit (the artifact this PRD produces)

Every rail, marked. The dispositions are the input to the tickets.

| rail | template requires | turbo-carnival today (2026-10-19) | disposition |
|---|---|---|---|
| R1 stack | Rails 8 · pg · Puma · importmap · Turbo/Stimulus · **HAML** · ViewComponent · Tailwind | Rails 8.1 · pg · Puma · importmap · Turbo/Stimulus · **ERB** · ViewComponent · Tailwind | **ADOPT — Q1** (HAML transition, deprioritised) · **ADOPT — Q5** (retire `solid_*`; Sidekiq only) |
| R2 Turbo | head `meta` trigger + body marker + importmap/controllers | meta ✓ · controllers (5) ✓ · `importmap.rb` ✓ · body marker ✗ | **GAP** (marker) · **RATIFIED** (trigger present) |
| R3 command | `GLCommand::Callable` + `ApplicationCommand#run_after_commit` | `GLCommand::Callable` ✓ · `ApplicationCommand` ✗ (F1) | **GAP** — port byte-identical + reparent + spec |
| R4 packs | packwerk + pack autoload wiring | packwerk ✓ · 12 packs ✓ · wiring via **`packs-rails`** (superset) · 47 offenses | **DEV — RATIFY** (`packs-rails`) · offenses = **PRD 0003 / #46** |
| R5 BDD | Cucumber + `gherkin_specs/` + lints | absent | **ADOPT — Q2**, scoped to the **Rails app only** (Layer 1 notation is house-wide; Layer 2 executable is Rails-only) |
| R6 gates | `bin/verify` incl. bundler-audit · erb_lint | `bin/verify` ✗ (PRD 0003) · bundler-audit ✗ · erb_lint ✗ (F3) | **GAP** (gate members) · `bin/verify` = **PRD 0003 / #47** |
| R7 observe | Sentry + DSN + `Sentry::Metrics` | no initialiser, no DSN, no reference (F2) | **GAP** — DSN provisioned by an **agent ticket** (Q3; the token exists, not `founder_needed`) |
| R8 govern | AGENTS · THESIS · FOUNDERS · PR template · docs/prd · tech_design_docs · `bin/lint` | AGENTS ✓ (PRD 0003) · THESIS inert (F7) · FOUNDERS ✗ · PR template ✗ · docs/prd README ✗ · tech_design_docs ✗ · packs/README ✗ · `bin/lint` ✗ | **GAP** (stubs) · **GAP** (thesis) · **ADOPT — Q4** (doc homes) |
| R9 rswag | swagger gen + verify, when `swagger/` exists | no `swagger/` | **N/A** — rail dormant; adopt only if an API surface appears |

**Also missing gems the template pins:** `strong_migrations`, `timecop`, `n_plus_one_control`,
`database_cleaner(+active_record)`, `rswag-api/specs`, `cucumber(+rails)`, `gherkin_lint`, `haml-rails`,
`aasm`, `oj`. **Present already:** `gl_command` ✓, `view_component` ✓, `tailwindcss-rails` ✓,
`dotenv-rails` ✓, `rspec-rails` ✓, `factory_bot_rails` ✓, `shoulda-matchers` ✓, `packwerk` ✓. Each missing
gem is adopted **only with the rail it serves** — a gem for a rail the repo does not run is the
vacuous-gate anti-pattern. Under the rulings: `haml-rails` rides on **Q1** (HAML transition), `cucumber` +
`gherkin_lint` on **Q2** (Rails-scoped lane), `strong_migrations` on **R6**; `rswag-api/specs` stays
**N/A** until a `swagger/` surface exists; `aasm` is **not adopted** — `state_machines-activerecord` is
ratified (Q7) — and `oj` remains unruled.

## Metrics / definition of done

Each line maps to an **enforced gate** (the harness DoD→gate rule); a line naming a **number** additionally
maps to an **emitted metric** (`Sentry::Metrics`), or it is untracked.

- **A parity audit script exists** and prints one line per rail; it exits non-zero while any rail is `GAP`.
  *Gate:* the script is run in CI and its output is attached to the conforming PR.
- **`ApplicationCommand` exists, is byte-identical to the template's, and every command subclasses it.**
  *Gate:* a spec asserting an after-commit side effect does not fire on rollback.
- **Sentry initialises and captures an event when a DSN is present.** *Gate:* a spec raising in a
  configured env asserts capture; **and** `Sentry::Metrics` emits the charter gauge
  (`growth.followers`, `growth.required_per_day`) and the pipeline acceptance counter.
- **`bin/verify`'s gate set matches the template's, minus the rails this repo ratifies as deviations.**
  *Gate:* `bundler-audit` and `erb_lint` are `bin/verify` members and run in CI.
- **`FOUNDERS.md` exists, status-tagged, every pillar carrying Lock / Enforcement / Red line.**
  *Gate:* reviewed against the template's pillar table.
- **A live `THESIS.md` (or a recorded decision to keep the thesis in `strategy-v2.md`).** *Gate:* the
  status line reads CURRENT, not HISTORICAL, and PRDs cite it.
- **`.github/pull_request_template.md`, `docs/prd/README.md`, `docs/tech_design_docs/`, `packs/README.md`
  exist.** *Gate:* byte-identical to the template's, where the template emits them.
- **`<body data-turbo-morph>` present, and the layout spec asserts the head `meta` trigger.** *Gate:* a
  spec failing if the meta is removed.
- **HAML is adopted as a deprioritised transition** — a ticket exists and nothing treats it as a blocker.
  *Gate:* the ticket is on the board in W1.4. (Q1)
- **`sidekiq` is the only job substrate.** `config.active_job.queue_adapter` is `:sidekiq`, no
  `solid_queue`/`solid_cache`/`solid_cable` remains in `Gemfile`, and no new `solid_*` usage is introduced.
  *Gate:* `bin/verify` fails on a `solid_*` reference and on a non-Sidekiq adapter. (Q5)
- **The Cucumber lane exists, is scoped to the Rails app, and gates.** `gherkin_specs/` + step definitions
  + `.gherkin_lint.yml`, in `bin/verify` and CI on day one; a failing Rails-app scenario turns the gate red.
  Non-Rails behaviour stays Layer-1 only. *Gate:* `cucumber` and `gherkin_lint` are `bin/verify` members.
  (Q2)
- **The two-layer Gherkin rule is documented where agents read it** — `AGENTS.md` and `docs/prd/README.md`.
  *Gate:* the text is present in both. (Q2)
- **The template's doc homes exist and the repo's `docs/` documents are reconciled into them, one truth per
  topic.** *Gate:* byte-identical to the template's where the template emits the file. (Q4)
- **The deviations table is complete** — no rail left without a disposition. *Gate:* the parity script
  reports `DEVIATION(reason)` for every non-conforming rail and `GAP` for none.

## Open questions

**Resolved 2026-10-19 — see *Founder rulings* above.** Q1 HAML (adopt, deprioritised) · Q2 Gherkin (adopt,
scoped to the Rails app; the two-layer rule) · Q3 Sentry DSN (an agent provisions it) · Q4 doc homes
(adopt) · Q5 job substrate (Sidekiq) · Q6 scope (stand alone at W1.4) · Q7 state-machine library
(`state_machines-activerecord` ratified over `aasm`) · Q9 non-Rails Gherkin definitions stay **inline in the
PRD**; only Rails-app scenarios become `.feature` files.

**Still open:**

1. **`packs-rails` vs the template's explicit autoload block (Q8).** The repo loads packs through the
   `packs-rails` gem; the template emits `Dir[Rails.root.join("packs/*/app/*")]` in `config/application.rb`.
   Measured 2026-10-19: the railtie (`Packs::Rails::Railtie`, packs-rails 0.1.0) puts **32** pack dirs on the
   autoload paths and **12** on the view paths, and `Rails.autoloaders.main.eager_load` resolves both
   `Growth::Goal` and `Scheduling::FailedPostRetry` — so the **mechanism** (pack classes load; packwerk
   enforces the boundary) is satisfied. The template hand-wires because it pins `packwerk` but does **not**
   ship `packs-rails`. *Lean: ratify `packs-rails`.* (Founder — asked.)

---

Drift note (gherkin-specialist): this PRD carries its acceptance criteria as Gherkin **scenarios inside the
PRD** — Layer 1 (notation), per house style. Q2 ruled **adopt**, so the Rails-app-facing scenarios here (the
parity script, the `ApplicationCommand` after-commit, the Sentry capture, the Turbo `meta` assertion) become
the first `gherkin_specs/harness/*.feature` files with lineage tags; scenarios describing non-Rails tools
(the ComfyUI/render stages) stay definitions, are never executed in Ruby, and are never moved into a
`.feature` file (Q9). Do not maintain two copies of any one scenario.
