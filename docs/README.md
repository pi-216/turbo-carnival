# Documentation index — what is current truth

> **Status:** CURRENT — the documentation index — start here

**Read this first.** This project accumulated ~20 process documents across two eras, several undated
and unmarked, so a new agent cannot tell which one is authoritative. This file is the answer to that
question and nothing else. **Anything not listed here is not truth** — if you find an unlisted
document, list it or archive it before acting on it.

The documentation is organised around **four root doc homes** — `ARCHITECTURE.md`, `CONTRACTS.md`,
`OPS.md`, `DESIGN.md` — each owning one topic, with the rest of the docs as specialised homes (the
spine, the strategy, the experiment lane, the validated render config) and superseded documents
under `docs/archive/`.

## The rule (why this file exists)

Every document carries a one-line status directly under its title:

| status | means |
|---|---|
| **CURRENT** | describes how the project works *now*. Act on it. |
| **REFERENCE** | accurate as a record or a comparison; not instructions. Read for context. |
| **HISTORICAL** | what happened at a point in time. Never instructions. |
| **UNREVIEWED** | not checked in the 2026-10-18 cleanup. Read, but confirm before acting. |
| **SUPERSEDED BY …** | kept for provenance only. Do not act on it. |

**When you change how the project works, update the CURRENT document. Do not write a new `v(N+1)`
alongside it.** One truth per topic — the four doc homes below exist so that a topic resolves to
exactly one CURRENT document, and each home points at the others rather than duplicating them.

---

## The four doc homes (created 2026-10-21, issue #82 / PRD 0006 F4)

| home | owns |
|---|---|
| **`ARCHITECTURE.md`** (root) | the app's structure: stack, pack boundaries (Packwerk), the command rail, the render pipeline (*shape*), the brain seat, the growth harness + two-venue design, the data spine (*shape*). |
| **`CONTRACTS.md`** (root) | the behavioral and data contracts: the legal floor, each gate's contract (measure / verdict / failure mode), the command + state-machine contracts, the claim contract, the agent test-signal contract, the two-layer Gherkin contract, the attribution spine, the serving-layer contract. |
| **`OPS.md`** (root) | operations: the `bin/verify` Tier-0 gate, the honest `bin/*.sh` + `bin/*.py` command inventory, the cron fleet (app scheduler + the agent-driven profile crons), the GPU claim lifecycle, the ComfyUI + brain runbooks, the render-pipeline mechanics (token system, authoring), environment, deploy, backups. |
| **`DESIGN.md`** (root) | the app UI design system: Tailwind v4 tokens, the ViewComponent library, navigation architecture, the lookbook, the preview/testing convention. |

The specialised homes below (the spine, strategy, experiment lane, validated render config) are
*cross-referenced* by the four homes — each carries the truth for its own topic.

---

## One truth per topic

| question | the authoritative document | do not use |
|---|---|---|
| What is the venture, and what will it never do (problem / user / value + founder red lines)? | **`THESIS.md`** | the agent-authored red lines of the HISTORICAL revision (git history; withdrawn 2026-10-18) |
| What work exists, in what order, and why? | **`PROJECT_PLAN.md`** | — |
| How does the project operate (blocks, authority, promotion)? | **`AGENTS.md`** (*the authority ladder*) + **`PROJECT_PLAN.md`** §2–3 | `strategy-v2.md` §8–13, `THESIS.md` |
| What is the app's structure (packs, command rail, render pipeline, brain seat, growth harness, data spine)? | **`ARCHITECTURE.md`** | — |
| What are the behavioral/data contracts (the legal floor, each gate, commands, the claim contract, the test signal, the attribution spine)? | **`CONTRACTS.md`** | — |
| How do you operate it (the verify gate, the command inventory, the cron fleet, the GPU/ComfyUI/brain runbook, deploy)? | **`OPS.md`** | — |
| What is the app's UI design system (Tailwind v4 tokens, the ViewComponent library, navigation, the lookbook)? | **`DESIGN.md`** | — |
| Why is the strategy what it is (distribution diagnosis, venues, platforms)? | **`strategy-v2.md` §1–7, §12.4** | `THESIS.md` |
| What is the validated render configuration (node ids, shas, the attribution table)? | **`baseline-config.md`** | any render doc predating 2026-10-18 |
| What experiments exist and what did they decide? | **`experiment-backlog.md`** | — |
| What is the safety/risk posture, and what stays a hard gate? | **`prd/0007-safety-posture-reduction.md`** (the legal floor + the A/B/C triage of the agent-authored controls; the floor is mirrored in `THESIS.md`, and the per-gate contracts live in `CONTRACTS.md`) | ad-hoc "founder ruling" phrasing, the HISTORICAL revision's red lines (git history) |
| How are tickets cut and linked? | **`PROJECT_PLAN.md` §4** | `bin/publish_prd` (dropped 2026-10-18) |
| How is the board wired? | **`config/autonomous/pipeline.yml`** | — |
| What is the render engine's node topology? | **`baseline-config.md`** | `lily-vs-sarah-hand-inpaint.md` (a comparison, not the config) |

---

## Inventory

### Current

| document | what it is |
|---|---|
| `ARCHITECTURE.md` (root) | the architecture home — see "The four doc homes" |
| `CONTRACTS.md` (root) | the behavioral/data-contract home — see "The four doc homes" |
| `OPS.md` (root) | the operations home — see "The four doc homes" |
| `DESIGN.md` (root) | the app UI design-system home — see "The four doc homes" |
| `PROJECT_PLAN.md` | **the spine.** Workstreams, ordering, ticket linkage contract, standing obligations |
| `AGENTS.md` (root) | house conventions for this repo — the authority ladder, the gate, ticket-claiming rules. Replaced the OpenSpec managed block 2026-10-19 |
| `THESIS.md` | **the thesis.** Problem / user / value, the "We will NOT" list (founder-authored red lines only — the legal floor first, `prd/0007` §1), and the five locked pillars. Rebased to CURRENT 2026-10-21 (ticket #81, PRD 0006 F7); the HISTORICAL revision's agent-authored red lines were withdrawn 2026-10-18 (`strategy-v2.md` §12.3) |
| `strategy-v2.md` | distribution diagnosis, the two-venue design, platform findings, salvage map. *(§8–13 process sections are superseded by the authority ladder in `AGENTS.md`)* |
| `experiment-backlog.md` | every experiment: pre-registration, verdict, and why. The evidence ledger |
| `baseline-config.md` | the validated baseline workflow: node ids, shas, the attribution table (the render-pipeline *values*; the token system is in `OPS.md`) |
| `scene-notes-bedroom-front.md` | design notes for the active scene (scene text is the prompt; notes live here) |
| `prd/` | the PRDs. `0001` local brain + phase machine · `0002` versioned content config + experiment DB spine · `0003` repo conventions + a verifiable done · `0004` the experiment lane — the contract every experiment must satisfy · `0005` the revealing-miniskirt pillar — the first experiment, and the contract's first test case · `0006` harness conformance to `rails-venture-template` — the parity audit and the rails this repo lacks · `0007` safety-posture reduction — the legal floor and the A/B/C triage of the agent-authored controls · `0008` the brain seat served by Ollama — re-points the seat's serving requirement off `llama.cpp`'s `llama-server`, with the capability price stated. Cut into board tickets per the plan's linkage contract |
| `tech_design_docs/` | one technical design doc per significant feature (`DEV-XXXXX_kebab-case-title.md`) — the PRD 0006 Q4 design-doc stubs |
| `pm/red-lines.md` | the founder-owned list of ruled-out-forever topics (the suggestion lane reads it; agents never edit it) |
| ~~`strategy-v3.md`~~ | **REMOVED 2026-10-19** — the operating model was duplicated across three documents, which is the drift this index exists to prevent. The authority ladder moved to `AGENTS.md`; the workstream contracts and the two founder requirements to `PROJECT_PLAN.md` §2; promotion to `PRD 0004`. Recoverable via `git log -- docs/strategy-v3.md` |

### Reference

| document | what it is |
|---|---|
| `lily-vs-sarah-hand-inpaint.md` | Sarah-vs-Lily inpaint comparison. Concluded: the inpaint paths are equivalent; the differences are upstream |
| `second-render-path.md` | the max395 (Strix Halo / ROCm) second render path — a how-to, not a commitment |

### Unreviewed — not touched in the 2026-10-18 cleanup

| document | what it is |
|---|---|
| `README.md` (root, the app overview) | large enough to be its own truth source; its "Project Documentation" section now points at the four doc homes |

### Historical — superseded, kept for provenance (under `docs/archive/`)

For issue #82 the pre-rebuild guides, the Catalyst/integration reports, the archived design-system
docs and the app's design-system file were moved to `docs/archive/` — their content now lives in the
four doc homes:

| document | why it is here |
|---|---|
| `archive/PIPELINE_SETUP.md`, `archive/WORKFLOW_VARIABLES.md`, `archive/instagram-scheduling.md` | absorbed into `OPS.md` |
| `archive/CONVENTIONS.md` | command/state-machine/packwerk conventions now in `ARCHITECTURE.md` + `CONTRACTS.md`; house rules in `AGENTS.md` |
| `archive/DESIGN_SYSTEM.md`, `archive/view_components.md`, `archive/nav.md`, `archive/navigation-architecture.md`, `archive/viewcomponent-guidelines.md`, `archive/progress.md` | the app UI design system — now `DESIGN.md` |
| `archive/CATALYST_MIGRATION_SUMMARY.md`, `archive/CLUSTER_REMOVAL_SUMMARY.md`, `archive/CREDENTIALS_STATUS.md`, `archive/INTEGRATION_REPORT.md`, `archive/INTEGRATION_ROADMAP.md`, `archive/PERSONAS_INTEGRATION_STATUS.md`, `archive/PERSONA_INTEGRATION_SUMMARY.md`, `archive/migration_audit_notes.md` | early integration/migration summaries — historical provenance only |
| `archive/SESSION_NOTES.md`, `archive/SESSION_NOTES_DEC3_EVENING.md` | early session notes (Dec 2024) — the only record of how the current tree was assembled; restored from git history, historical provenance only |
| `brainstorming.md` | early ideation (provenance) |
| `post-creation-interface.md` | an implementation-progress log, not a spec |
| ~~`openspec/`~~ (114 files) | **REMOVED 2026-10-19** — dropped in favour of the PRD/ticket system. Recoverable from git history (`git log -- openspec`) |
| `archive/` | documents moved here during cleanup |
