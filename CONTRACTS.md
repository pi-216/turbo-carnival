# CONTRACTS.md — turbo-carnival

> **Status:** CURRENT — the behavioral/data-contract home.
>
> **Provenance** — created 2026-10-21 for issue #82 (PRD 0006 F4). Before this file existed,
> the contracts were spread across `AGENTS.md`, the gate source, `bin/verify`, the PRDs and the
> pre-rebuild guides. The **shape** of the system is in `ARCHITECTURE.md`; **how to operate it**
> is in `OPS.md`; the **UI** is in `DESIGN.md`. This file is where the *behavioral and data
> contracts* — the promises the code makes and holds — resolve to one document each.
>
> A contract is a promise with an enforcement point. Each entry below names the promise, the
> code that holds it, and what happens when it breaks. When code and this file disagree, the code
> wins; divergences are called out at the bottom.

## What this file owns (one truth per topic)

| Topic | Home |
|---|---|
| The legal floor (the one hard gate) | **this file** (the authority ladder → `AGENTS.md`) |
| Each gate's contract: measure, verdict, failure mode | **this file** |
| The command rail contract (GLCommand) | **this file** (the rail's *shape* → `ARCHITECTURE.md`) |
| The state-machine contract | **this file** |
| The claim contract (board status + labels) | **this file** |
| The agent test-signal contract | **this file** |
| The two-layer Gherkin contract | **this file** |
| The data / attribution spine contract | **this file** (the spine's *shape* → `ARCHITECTURE.md`) |
| The serving-layer contract (the brain seat) | **this file** |

## The legal floor — the one hard gate

Everything else in the harness is a *control* (ranks, measures, informs); exactly one thing is a
*gate*: the **legal floor** (`AGENTS.md` — "The one hard gate"). The floor has three parts, and a
floor question always **fails closed**:

1. **Adult (18+).** No render that *reads* minor is published. Enforced by `Growth::PersonaAgeGate`.
2. **No real-person likeness.** Only the synthetic persona.
3. **Synthetic mark.** Every asset carries the embedded synthetic mark.

> An agent may not promote its own safety preference into a founder red line; and it may not
> demote a floor question to an advisory one. The floor is class 4 (identity / persona age read —
> Sarah, 18) plus the mark, per the authority ladder in `AGENTS.md`.

## Gate contracts

The harness runs a set of gates over each asset. Each is either **floor** (fail-closed) or
**advisory** (fail-open, score persisted, loud log). Where the truth of a gate's current behavior
lives, the code is authoritative.

| Gate | Class | Verdict of record | Failure mode |
|---|---|---|---|
| `Growth::PersonaAgeGate` | **floor** | band + tier on `caption_metadata.age_gate` | **fail-closed** on explicit (band bottom < 18); SFW unreadable reads **fail open** with a per-run log |
| `Growth::NsfwGate` | advisory | `flagged` (score persisted on `photos.nsfw_score` / `nsfw_flagged`) | **fail-open**; unmeasured states fail open with a loud log |
| `Growth::RealismGate` | advisory | a realism score | **fail-open** (realism is the last veto until #110 retires it) |
| Synthetic mark | **floor** | present / absent | **fail-closed** |
| `Growth::BrainGate` | advisory | whether the brain seat answered | fails open (degrades by value) |
| `Growth::NearDuplicateGate` | advisory | duplicate score | advisory |
| `Growth::SchedulerGate` | control | `comfyui_unclaimed` etc. | gates a *step* (GPU claim), not an asset |

**Contracts that matter (the ones that have bitten us):**

- **NSFW is advisory, not a veto (PRD 0007 A1, #104).** `Growth::NsfwGate` has **no `safe` member
  and no reject/purge branch**. A flagged asset is *eligible content*; the `nsfw_rejected` /
  `nsfw_purge` path and the CadenceEngine NSFW pillar-rotation are retired. The score is persisted
  on the asset row. Unmeasured states (NULL) are **not** `false` — they fail open with a log.
- **The age gate is band-based and tier-aware (PRD 0007 B1, #108).** It does not ask "is this
  minor?" — it reads an **age band** and compares against the **tier**: SFW passes when the band
  top ≥ 18; explicit passes when the band bottom ≥ 18. Ambiguous/unparseable explicit reads fail
  **closed** (held); ambiguous SFW reads fail **open**. The band and tier are recorded on the run
  row, and holds log the parsed read. This is the dominant content constraint, not the NSFW score.
- **The mask guard's protection is its polarity** (house trap): `LazySwitchKJ` fires `on_true`
  when the mask is non-empty ⇒ `on_true` must go to the **inpainted** branch, `on_false` to the
  **raw** one. Inverted, it fails twice.

## The command-rail contract

Business logic is a chain of **GLCommand**s. The contract:

- Class names start with a **verb**; each command is small and single-purpose.
- `requires` / `returns` declare the interface; a chain **rolls back in reverse** if any step fails.
- Tests use GLCommand's RSpec matchers; `build_context` to stub a command with a real interface.
- The *shape* of the rail (where it sits, the pack layout) is in `ARCHITECTURE.md`; this entry is
  the *behavioral* promise.

## The state-machine contract

Models with state transitions use `state_machines-activerecord`; **status columns are strings**, not
integers. A state change is a machine transition, not an assignment. (The pre-rebuild `aasm`
reference is gone — the modern successor is what the app uses.)

## The claim contract (board status + labels)

The board *is* the queue and the audit trail (`config/autonomous/pipeline.yml`, board `pi-216`
project #5). A ticket is **claimed by flipping the board status and the labels together**, so
independent agents never double-claim. The labels:

| Label | Meaning |
|---|---|
| `ticket` | generated work ticket (autonomous agent) |
| `approved` | **product-owner gate** — an agent *may start*. **An agent may never add this.** |
| `agent_working` | claimed by an autonomous agent (in progress) |
| `agent_blocked` | blocked — agent may not work |
| `agent_needs_review` | needs human review before done |
| `pm-suggested` | PM-agent proposal awaiting a founder ruling (never also `approved`) |
| `needs-founder` | only the founder can act (a ruling, credential, platform setting, GPU policy, physical action) |

**Contract:** `approved` and `needs-founder` must never be overloaded — one means "an agent may
start", the other means "only the founder". A script that sets `approved` has removed the gate.
Nothing is destructive without the founder's explicit confirmation (archive, don't delete; export
before prune).

## The agent test-signal contract

Test runs are fired by **unobserved cron agents**, whose captured stdout *is* their context
window. `bin/rspec` owns a compact verdict channel (stable vocabulary — agents grep these
prefixes):

| Verdict | Meaning |
|---|---|
| `TESTS OK` | green — the only line that counts as a pass |
| `TESTS RED` | failures (with the diff) |
| `TESTS ZERO` | 0 examples ran — **not** a pass |
| `TESTS UNKNOWN` | aborted, no summary — **not** a pass |

- On a TTY (agent mode off) `bin/rspec` hands over to real rspec untouched; without a TTY or with
  `AGENT_TEST=1` it prints the verdict and writes the full, untruncated report to
  `~/.pi216/agent-test/<repo>-latest.log`.
- The gate is **verdict-gated, not exit-code-gated**: `bin/verify` requires exit 0 **and** the
  `TESTS OK` line, because rspec exits 0 on a zero-example run.
- `bin/rspec`, `lib/rspec/agent_formatter.rb` and `bin/test-agent-signal` are **byte-identical** to
  `rails-venture-template` at `8dc4586b941a` (fleet-wide parity); `bin/test-agent-signal` runs the
  formatter against synthetic ok/red/zero/load-error suites (12 contract checks) in CI.

## The two-layer Gherkin contract

Gherkin runs **two layers**, selected by the `@dev` tag:

- `feature` = **behavior** (what the system must do, in user terms).
- `spec` = **unit** (the mechanism).
- Scenario ids are `@DEV-NNNN`; a behavior spec and its unit spec share an id so the two layers
  cross-check.

## The data / attribution-spine contract

The `attribution` pack owns the unbroken chain from a published post back to its origin. The
contract: **a post that was published must carry a resolvable, unbroken chain** —

```
Photo.source  →  PipelineRun.id  →  gates' verdicts  →  Persona  →  Post.posted_at
```

- Every gate verdict of record is persisted on the run/asset row (age band+tier, NSFW
  score+flag, realism score), so a later audit can reconstruct *why* a post was published.
- A render created now references the **content config version** it ran under
  (`renders.content_config_version_id` → `content_config_versions`, PRD 0002 / #40). The version is
  **append-only**: a config change writes a new version, never an edit to an existing one. That is
  enforced three ways — the digest is derived from the pinned axes, `#readonly?` refuses every
  ActiveRecord write path, and a database trigger refuses `update_all`/raw SQL — because an
  editable version would rewrite the attribution of every render that referenced it, retroactively.
- A failed create is **never** reported as a no-op; a broken link in the chain is a defect to be
  repaired, not a status to be glossed over.
- The *shape* of the model graph is in `ARCHITECTURE.md`; this entry is the *contract* (what each
  link must carry and why).

## The serving-layer contract (the brain seat)

The brain seat is a **degrade-by-value** dependency, not a hard one:

- When the brain is up, probes use `model=brain`; when it is down, caption generation **degrades
  by value** with a `brain_unavailable` probe error and the gate skipped as fail-open — never a hard
  failure that blocks the harness.
- The seat and ComfyUI are never co-resident on the 4090; the serving contract is *availability*,
  not a SLA. The runbook for starting/stopping the seat is in `OPS.md`.

## Where reality diverges from this file

- **`Growth::RealismGate`** is advisory, and its older design note ("mirrors the NSFW gate's
  fail-closed contract") is **stale** — the NSFW gate no longer has a fail-closed contract to
  mirror (PRD 0007 A1). Realism is the last remaining veto until #110 retires it.
- **`Solid Queue`** appears in the Gemfile but is not the worker substrate (see
  `ARCHITECTURE.md` divergences) — the command/job contract is exercised on Sidekiq.
