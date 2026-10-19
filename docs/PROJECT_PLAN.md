# Project plan — turbo-carnival

> **Status:** CURRENT — the spine: workstreams, ordering, ticket linkage

**This document is the spine.** It is the only place that records *why* work exists, *in what order*,
and *how the pieces fit*. The board is the queue; this is the map. Entry point for anyone — human or
agent — asking "what should happen next, and why that?"

Founder, 2026-10-18: *"we don't need `publish_prd`, but we need a concept of a project plan that
connects every ticket."*

---

## 1. What this is, and what it deliberately is not

| it is | it is not |
|---|---|
| the rationale and ordering of all work | the queue — that is the board |
| hand-written judgement, with a **generated** index | a Gantt chart or a schedule |
| the answer to "why does this ticket exist" | a status tracker (the board owns state) |

Mixed documents rot. So the split is enforced: **prose here is hand-written, the index is derived
from the board.** See §5.

Board: https://github.com/orgs/pi-216/projects/5 · config: `config/autonomous/pipeline.yml`

---

## 2. The three workstreams

These mirror the board's `Track` field exactly — one field, so a ticket cannot be in two places.

| id | workstream | cadence | closes when |
|---|---|---|---|
| **W1** | core-infrastructure | build-now, one-off, blocking | the capability exists **and is proven** |
| **W2** | experiment | parallel, must never block W3 | a verdict is recorded — *a negative result closes too* |
| **W3** | day-to-day | recurring, unattended | **never** (§3) |

Block 1/2/3 from `docs/strategy-v3.md` map onto these: Block 1 ≈ W1, Block 2 ≈ W3, Block 3 ≈ W2.

---

## 3. Two kinds of item — the distinction that keeps the board honest

A plan that connects tickets must separate work that **finishes** from obligations that **never
finish**. Collapsing them is what turns a board into a graveyard of stale Todo items.

- **Deliverable** (W1, W2) — finite. A ticket that can reach Done.
- **Standing obligation** (W3) — infinite. The nightly engagement pull is not "done" on the day it
  ships; it is a promise that must hold every night.

So W3 items do **not** live on the board as long-running tickets. Each W3 item is defined here with:

- a **trigger** (cadence, or the event that fires it),
- a **health expectation** (how long a gap is normal before it is an incident),
- an **absence alarm** — silence is the failure mode, and a job that dies silently is worse than
  one that crashes loudly.

Board tickets inside W3 are therefore **interventions** ("the nightly pull missed 3 nights — find
out why"), which are deliverables and do close.

---

## 4. How a ticket connects (the linkage contract)

Every item in this plan gets a stable id — `W1.1`, `W3.2`. The id is the join key between plan and
board, and it never gets renumbered once a ticket cites it.

**Every ticket carries this block, in this order:**

```
Plan       : docs/PROJECT_PLAN.md#w11-local-brain-and-phase-machine
PRD        : docs/prd/0001-local-uncensored-brain-and-phase-machine.md
Track      : core-infrastructure
Role       : agent-worker | script-worker
Depends on : #12            (empty means ready)
Blocks     : #14, #17
Serves     : <the one goal line this ticket advances>
```

That is five distinct connections, and each answers a question the board alone cannot:

| field | question it answers |
|---|---|
| `Plan` | why does this exist at all |
| `PRD` | what was agreed, in full |
| `Track` | which cadence am I on |
| `Role` | judgement or mechanics — who may pick this up |
| `Depends on` / `Blocks` | may I start, and what do I unblock |
| `Serves` | what moves if this succeeds |

**Title convention:** `[W1.1] <verb-first summary>`. The id in the title is what makes the board
sortable by plan item and greppable from the plan.

---

## 5. Keeping it true

The failure mode of a plan document is drift. Two rules prevent it:

1. **The index in §7 is generated from the board, never typed.** Item → tickets → status is a query.
   Regenerate on demand (`rake plan:index`) or before any review.
2. **`rake plan:check` fails on:** an open board item citing no plan id; a plan id citing a closed
   issue as open; a dependency cycle; a `Depends on` pointing at a ticket that is not Done while this
   one is In Progress.

The check is what makes this a plan rather than a wish: it is the only mechanism that notices when
the board and the plan have diverged.

---

## 6. Ordering — what blocks what

Ordering is the part the board cannot express, so it is stated here explicitly.

- **W1.1** (local uncensored brain + phase machine) blocks **W3.3** and **W3.4** — the planners that
  decide *what* to generate cannot run on the hosted model, and cannot be co-resident with ComfyUI.
- **W1.2** (versioned content config + experiment DB spine) blocks **all of W2** — without capture,
  no experiment is attributable — and blocks **W3**, which must point at a *version*.
- **W1.3** (repo conventions) blocks no capability but blocks **every agent working a ticket**, so it
  is on the critical path for autonomy even though nothing depends on it technically.
- **W3.5** (close the render loop) depends on **W2.1** — a rail that dies at random on an empty mask
  cannot be the engine of an unattended pipeline.

---

## 7. Items

_W1.1 is the first item being specified. The rest are placeholders with their rationale fixed and
their tickets not yet cut._

### W1 — core-infrastructure

| id | item | PRD | state |
|---|---|---|---|
| **W1.1** | local uncensored brain + phase machine | `docs/prd/0001-…` | **spec written** · tickets #20, #22–#27 · **blocked on #22** (founder) |
| W1.2 | versioned content config + experiment DB spine | `docs/prd/0002-…` | **spec written** · epic #36, tickets #37–#43 |
| W1.3 | repo conventions — `AGENTS.md`, `verify`, board wiring | `docs/prd/0003-…` | **OpenSpec dropped** `7e5ccee` · epic #44, tickets #45–#50 |

- **W1.1** — the planners currently run on a hosted, risk-averse model that hedges on briefs that are
  legal and in-lane. The replacement is the local uncensored Qwen3.8-27B. Intake confirmed the brain
  and ComfyUI cannot be co-resident (22.08 GB of 24 GB), so the phase machine is a hard requirement,
  not a preference. **Serves:** a Thinker that proposes without moralising, and renders that happen
  on the same box.
- **W1.2** — raw capture (models, prompts, **prompt parts**, seeds, time-of-day, weekday) keyed on
  `sha256`, so one query answers *which combination produced the images that earned the most
  non-follower reach*. **Serves:** attribution — the difference between evidence and anecdote.
- **W1.3** — the OpenSpec estate is **gone**: dropped by the founder 2026-10-19, `AGENTS.md` rewritten as
  this repo's house conventions, `openspec/` (114 files) and its three workflow prompts removed,
  `agents_md` repointed at something true. What remains is the **gate**: a `bin/verify` over the **rspec**
  suite (630 examples — CI today runs an empty Minitest lane and reports green while executing nothing), a
  **clean** `packwerk check` (46 offenses today), and `plan:check` as a **rake task** (the app runs anyway
  to serve IG assets through the Cloudflare tunnel). `publish_prd` is **deliberately not ported** (founder,
  2026-10-18) — tickets are cut by the agent against this plan. **Serves:** an agent that can be trusted
  with a ticket.

### W2 — experiment

| id | item | PRD | state |
|---|---|---|---|
| W2.1 | **the experiment lane** — the contract every experiment must satisfy | `docs/prd/0004-…` | **spec written** 2026-10-19 |
| W2.2 | the E-lane discipline (pre-registration, blinding, decoders) | — | folds into W2.1 |
| W2.3 | **experiment: the revealing-miniskirt pillar** | `docs/prd/0005-…` | **spec written** 2026-10-19 · folder `experiments/0005-miniskirt-pillar/` |
| — | render-axis experiment, parked | *its own PRD required* | un-run; keep/drop is the founder's call (§8) |

- **W2** — the lane is a **contract**, not a list of experiments. Each experiment gets **its own PRD**, its
  own code folder `experiments/<PRD-number>-<slug>/`, a **designated researcher**, and its own tickets.
  The lane supplies: the admission rule (one axis, frozen decision rule, a named instrument, a pre-committed
  handling for an invalid measurement), one shared decode instrument, the promotion rule (automatic on a
  pre-registered threshold — the founder is advisory input, never a gate), and the **isolation guarantee**:
  **the day-to-day flow does not depend on an experiment.** Roles: the **Thinker** proposes
  (*"try a miniskirt pillar and see if people react"*); the **researcher** owns one experiment end-to-end,
  including evaluating data, generating its images, and asking for eyes; the founder is the instrument.
  **Serves:** the system answering its own open questions without a human in the loop and without the
  daily flow ever waiting on research.

### W3 — day-to-day (standing obligations)

| id | item | trigger | health expectation |
|---|---|---|---|
| W3.1 | pull engagement per asset | nightly | one night missed = normal, three = incident |
| W3.2 | decide whether new content is required | after W3.1 | — |
| W3.3 | decide *what* to generate | on W3.2 demand | blocked by **W1.1** |
| W3.4 | file generation requests | on W3.3 output | blocked by **W1.1** |
| W3.5 | pick up requests → ComfyUI → close the loop | continuous | blocked by **W2.1** |

---

## 8. Open questions

- **Does the experiment lane inherit the parked render experiment, or start clean?** Under PRD 0004 that
  experiment would need **its own PRD** to run at all. Whether it is kept, re-registered, or dropped is the
  **founder's call** — deliberately not decided by the PRD or by an agent.

- ~~**Repo ownership vs board ownership.**~~ **Resolved 2026-10-18: the repo moved to
  `pi-216/turbo-carnival`.** Board owner and repo owner are now the same account, so
  `config/autonomous/pipeline.yml` is back to the house's single-`owner` shape (it briefly needed a
  split `board_owner`/`repo` pair while a personal repo fed an org board).
- **Where the index is regenerated.** A rake task in the app, or a standalone script in `bin/`?
  (Lean `bin/` — it must run without booting Rails.)
- **W2 item granularity.** One plan item per experiment (E5, E6, …), or one item for the lane with
  tickets per experiment? *Lean: tickets per experiment, so the lane's closure is legible.*
