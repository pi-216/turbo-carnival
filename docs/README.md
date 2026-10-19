# Documentation index — what is current truth

> **Status:** CURRENT — the documentation index — start here

**Read this first.** This project accumulated ~20 process documents across two eras, several undated and
unmarked, so a new agent cannot tell which one is authoritative. This file is the answer to that question
and nothing else. **Anything not listed here is not truth** — if you find an unlisted document, list it or
archive it before acting on it.

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
alongside it.** `strategy-v2.md` + `strategy-v3.md` + `THESIS.md` all describing the operating model is
exactly how this file became necessary.

---

## One truth per topic

| question | the authoritative document | do not use |
|---|---|---|
| What work exists, in what order, and why? | **`PROJECT_PLAN.md`** | — |
| How does the project operate (blocks, authority, promotion)? | **`strategy-v3.md`** | `strategy-v2.md` §8–13, `THESIS.md` |
| Why is the strategy what it is (distribution diagnosis, venues, platforms)? | **`strategy-v2.md` §1–7, §12.4** | `THESIS.md` |
| What is the validated render configuration? | **`baseline-config.md`** | any render doc predating 2026-10-18 |
| What experiments exist and what did they decide? | **`experiment-backlog.md`** | — |
| How are tickets cut and linked? | **`PROJECT_PLAN.md` §4** | `bin/publish_prd` (dropped 2026-10-18) |
| How is the board wired? | **`config/autonomous/pipeline.yml`** | — |
| What is the render engine's node topology? | **`baseline-config.md`** | `lily-vs-sarah-hand-inpaint.md` (a comparison, not the config) |

---

## Inventory

### Current

| document | what it is |
|---|---|
| `PROJECT_PLAN.md` | **the spine.** Workstreams, ordering, ticket linkage contract, standing obligations |
| `strategy-v3.md` | the operating model — three blocks, risk ladder, raw-data capture, promotion |
| `strategy-v2.md` | distribution diagnosis, the two-venue design, platform findings, salvage map. *(§8–13 process sections are superseded by v3)* |
| `experiment-backlog.md` | every experiment: pre-registration, verdict, and why. The evidence ledger |
| `baseline-config.md` | the validated baseline workflow: node ids, shas, attribution table |
| `scene-notes-bedroom-front.md` | design notes for the active scene (scene text is the prompt; notes live here) |
| `design-system/` | ViewComponent + navigation guidelines for the app UI |
| `prd/` | the PRDs. `0001` local brain + phase machine · `0002` versioned content config + experiment DB spine · `0003` repo conventions + a verifiable done · `0004` the experiment lane — the contract every experiment must satisfy. Cut into board tickets per the plan's linkage contract |

### Reference

| document | what it is |
|---|---|
| `lily-vs-sarah-hand-inpaint.md` | Sarah-vs-Lily inpaint comparison. Concluded: the inpaint paths are equivalent; the differences are upstream |
| `second-render-path.md` | the max395 (Strix Halo / ROCm) second render path — a how-to, not a commitment |

### Unreviewed — not touched in the 2026-10-18 cleanup

Predate the rebuild; some are certainly stale, but nothing here is known-wrong either. **Confirm before
acting.** Each should be promoted to CURRENT or moved to `archive/` at the next cleanup.

| document | age | what it claims to be |
|---|---|---|
| `PIPELINE_SETUP.md` | 2025-11 | pipeline setup guide |
| `WORKFLOW_VARIABLES.md` | 2025-11 | workflow token/variable guide |
| `CONVENTIONS.md` | 2025-11 | code conventions |
| `view_components.md` | 2025-11 | ViewComponent guide |
| `nav.md` | 2025-12 | left-hand navigation |
| `instagram-scheduling.md` | 2025-12 | Instagram scheduling setup |
| `README.md` (root, 983 lines) | — | app overview; large enough to be its own truth source |

### Historical — superseded, kept for provenance

| document | why it is here |
|---|---|
| `THESIS.md` | the original thesis. Its content-strategy section is superseded by `strategy-v2.md`; one of its red lines (the Pornmaster prohibition) was **agent-authored, not founder-authored**, and was withdrawn 2026-10-18 |
| `brainstorming.md` | early ideation |
| `post-creation-interface.md` | an implementation-progress log, not a spec |
| `AGENTS.md` (root) | **CURRENT** — house conventions for this repo. Replaced the OpenSpec block 2026-10-19 |
| ~~`openspec/`~~ (114 files) | **REMOVED 2026-10-19** — dropped in favour of the PRD/ticket system. Recoverable from git history (`git log -- openspec`) |
| `archive/` | documents moved here during cleanup |
