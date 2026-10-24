# OPS.md — turbo-carnival

> **Status:** CURRENT — the operations home.
>
> **Provenance** — created 2026-10-21 for issue #82 (PRD 0006 F4). It absorbs the operational
> truth that was living in `docs/PIPELINE_SETUP.md`, `docs/WORKFLOW_VARIABLES.md`,
> `docs/instagram-scheduling.md` and the `bin/*.sh` headers (now archived under
> `docs/archive/`). The **shape** of the system is in `ARCHITECTURE.md`; the **contracts** are in
> `CONTRACTS.md`; the **UI** is in `DESIGN.md`.
>
> The command inventory below is written **against what the scripts actually do** — including the
> ones that are dead. If a script's real behavior changes, update this line; a stale ops line is a
> defect.

## What this file owns (one truth per topic)

| Topic | Home |
|---|---|
| The `bin/verify` Tier-0 gate | **this file** (its *contract* → `CONTRACTS.md`) |
| The `bin/*.sh` + `bin/*.py` command inventory (honest) | **this file** |
| The cron fleet (app scheduler + the agent-driven profile crons) | **this file** |
| The GPU claim lifecycle (the 4090's two tenants) | **this file** |
| The ComfyUI lifecycle + the brain-seat runbook | **this file** |
| The render-pipeline mechanics: authoring a workflow, the token system, worker config | **this file** (validated *values* → `docs/baseline-config.md`) |
| Environment, runbook, deploy, backups | **this file** |

## The Tier-0 gate: `bin/verify`

`bin/verify` is the single gate that makes "done" a state a machine can verify, not a claim an
agent makes about itself (PRD 0003; gate membership per PRD 0006 F3). It composes the existing
entry points in a fixed order and stops at the first failure:

```
bin/lint -> bin/brakeman --no-pager -> bundler-audit -> bin/packwerk check -> parity -> bin/rspec
  (cucumber + gherkin_lint follow rspec while any .feature files exist)
```

`bin/lint` is the single lint entry point (PRD 0006 R8 / ticket #91): rubocop
house style (repo-local `.rubocop.yml` via `bin/rubocop`, which also carries the
cgroup OOM guard) plus erb_lint, with `--branch` mode for the files changed vs
`origin/main`. `bin/verify` and CI call it, never the underlying linters.

- **Fail-closed:** a gate that cannot run (missing gem, missing DB, missing binstub) is a failure,
  never a pass.
- **Verdict-gated rspec:** the rspec gate requires exit 0 **and** the `TESTS OK` line (the
  agent-test-signal contract, `CONTRACTS.md`), because rspec exits 0 on a zero-example run.
- Run it (from the repo root, under RVM 3.4.5):
  `source /usr/share/rvm/scripts/rvm && rvm use 3.4.5 && bin/verify`

## The command inventory

The harness runs on the 4090 host. Shell harnesses and the Python ops tools:

| Command | What it actually does |
|---|---|
| `bin/verify` | The Tier-0 gate (6 gates above). |
| `bin/lint` | The single lint entry point — rubocop house style + erb_lint, repo-local configs; `--branch` lints the files changed vs `origin/main`. |
| `bin/rspec` | The agent test signal (TTY-aware; compact verdict + full log). |
| `bin/test-agent-signal` | Self-tests the rspec formatter against synthetic ok/red/zero/load-error suites (12 checks). |
| `bin/run_server.sh` | Start the Rails server — the growth-harness host, port **3004**, RVM 3.4.5, `RAILS_ENV=development`. |
| `bin/run_worker.sh` | Start the **Sidekiq** worker. Without it, `JobPollerWorker` never runs and no `ComfyuiJob`/`PipelineRun` reaches a terminal status. |
| `bin/comfyui_harness.sh` | The scheduler-gated ComfyUI lifecycle — `status` / `ensure` / `shutdown`. **The only way to launch ComfyUI** (it claims the GPU, never free-runs). |
| `bin/comfyui_debug_go.sh` | Claim the 4090 for an *interactive* ComfyUI debug session. |
| `bin/brain_harness.sh` | Start/stop the brain seat: claim the 4090, serve Qwen3.8-27B on `:8080`, release. Always leaves the card free. |
| `bin/brain_checkin.sh` | Cron wrapper for the brain check-in (#24, W1.1) — a silently-dead brain is an outage this catches. |
| `bin/brain_plan_nightly.sh` | The nightly planner window (PRD 0001, #64). |
| `bin/phase_handoff.sh` | The measured free-VRAM gate between the 4090's two tenants (ComfyUI and the brain). |
| `bin/scheduled_posting.sh` | **The live publisher.** Posts due drafts, driven hourly from the user crontab (`0 * * * *`). Logs to `log/scheduled_posting.log`. |
| `bin/growth_harness.sh` | **DEPRECATED 2026-09-20 — do not re-enable.** It ran the same `scheduling:post_scheduled` task on the same hourly cadence; re-adding it would put a second driver on the publisher (a two-driver read-modify-write race). Kept for history only. |
| `bin/ops_heavy.sh` | Run a memory-heavy command so it escapes the Hermes cron worker's 4 GiB cgroup (so a heavy verification does not OOM the tick). |
| `bin/corpus_backup.sh` | Put a **second copy** of the Sarah render corpus somewhere other than the primary, and verify it. |
| `bin/reel_rail_smoke.sh` | One-command smoke of the REELS publish rail. |
| `bin/tc_render.py` | Render a fixed-scene / varied-checkpoint sweep from a versioned workflow (the scene and seed stay fixed; only the base varies). |
| `bin/tc_workflow.py` | Workflow build/inspection tooling. |
| `bin/tc_ops.py` | Ops reporting (e.g. `age_hold_verdict` — the age-gate hold counts by tier). |
| `bin/aesthetics_gate.py`, `bin/nsfw_gate.py`, `bin/dhash.py`, `bin/library_depth.py` | The measurement tools: aesthetics, NSFW score, perceptual-hash near-duplicate, library depth. |

## The cron fleet

There are **two cron layers** and they are in different places:

**1. The app scheduler (runs the harness, in the repo's runtime).**
- **Sidekiq worker** (`bin/run_worker.sh`) — `JobPollerWorker` advances `ComfyuiJob`/`PipelineRun`
  to a terminal status. It must be running or the harness stalls.
- **The hourly posting rail** — `bin/scheduled_posting.sh` from the user crontab (`0 * * * *`).
  One post per tick, paced through `Scheduling::PostReleasePlan` (one release per tick), which also
  repairs placeholder captions, salvages abandoned renders and collects insights first.
- **The nightly planner window** — `bin/brain_plan_nightly.sh` (PRD 0001, #64).

**2. The agent-driven crons (operate the repo, in the Hermes profile — NOT in the repo).**
The live agent crons live in the turbo-carnival profile's `cron/jobs.json`
(`~/.hermes/profiles/turbo-carnival/cron/`), not in this checkout:
- **`ds4q-producer-dev-worker`** — hourly (`0 * * * *`), no-agent script: the dev-worker pipeline
  producer that works the board (`config/autonomous/pipeline.yml`) and builds PRs.
- **`ds4q-producer-pm-agent`** — weekly (`0 9 * * 2`), no-agent script: the PM suggestion pass
  (the suggestion lane, capped at 10 open, never `approved`).

> The agent crons are agent-driven (a "brain" reads the board and adapts), not dumb scripts — a
> preference of the founder's. When the profile's `jobs.json` is the source of truth for the fleet,
> this table is a summary; reconcile it against `hermes cron list` before relying on cadence.

## The GPU claim lifecycle (the 4090's two tenants)

One 24 GB RTX 4090 serves **two tenants that are never co-resident**: the ComfyUI render engine and
the brain seat (~22 GB loaded). The rule (a house convention enforced by `bin/comfyui_harness.sh`):
**ComfyUI runs only while this repo holds a GPU claim.**

- Claims go through the NAS scheduler (`gpu_scheduler.py`, `SCHED_DIR=/mnt/nas-ai-models/gpu-scheduler`).
- **ComfyUI:** `bin/comfyui_harness.sh ensure` claims the card and starts ComfyUI; `shutdown`
  releases it. `Growth::SchedulerGate` gates the harness on `comfyui_unclaimed`.
- **Brain:** `bin/brain_harness.sh` claims the card (23 GB), serves on `:8080`, and on stop
  SIGTERMs the server, verifies the port is closed and the GPU idle, then releases — always
  leaving the card free.
- **Between tenants:** `bin/phase_handoff.sh` is the measured free-VRAM gate.
- **The trap:** a shared-log crash is not yours until the graph's node fingerprint matches
  (fingerprint, don't timestamp).

## The ComfyUI lifecycle

`bin/comfyui_harness.sh` is the **only** sanctioned way to start ComfyUI (it is scheduler-gated).
`status` / `ensure` / `shutdown` are the verbs. For interactive debugging use
`bin/comfyui_debug_go.sh` (claims the 4090 for the session). Do not `nohup` a ComfyUI by hand —
an unclaimed server makes the scheduler report "idle" while the card is busy.

## The brain seat

The brain (PRD 0001) is a local uncensored Qwen3.8-27B-Uncensored-HauhauCS-Aggressive seat
(GGUF `Q4_K_M` + mmproj vision) on `:8080`, staged on the NAS and described as **data** in
`config/autonomous/brain.yml`. Start/stop it with `bin/brain_harness.sh`; the client is
`lib/ai/brain_client.rb`. When it is down, the harness degrades by value (the serving-layer
contract, `CONTRACTS.md`) — never a hard fail. `bin/brain_checkin.sh` is the cron that catches a
silently-dead seat.

## Render-pipeline mechanics

**Authoring a workflow.** A render is a versioned ComfyUI workflow JSON (e.g.
`comfy_workflows/turbo_one_step_v2/step1_generate.json`). The validated values live in
`docs/baseline-config.md` (regenerate rather than hand-edit). To reproduce a set:

```bash
/usr/bin/python3 bin/tc_render.py sweep --scene bedroom-front \
  --prompt-file scenes/bedroom-front.txt --out <POOL_DIR> \
  --checkpoints <CKPT1>,<CKPT2>,... --seed <SEED> --retries 2
```

**The token system.** Variables in a workflow JSON are substituted at job submission, in the
`Comfyui::BuildJobPayload` choke point. Two kinds:
1. **Template variables** — `{{name}}`, replaced in the JSON text before it is parsed (so they work
   anywhere). Available: `{{prompt}}`, `{{run_name}}`, any key in `PipelineRun.variables`, plus the
   system variables `{{timestamp}}`, `{{timestamp_ms}}`, `{{random}}` (0–999,999,999) and
   `{{auto_seed}}` (base seed + job id → a unique but deterministic seed per job).
2. **Runtime variables** — passed in the job payload's `variables` section, resolved after the JSON
   is parsed (for node inputs that must be typed).

**Prompt safety.** The image prompt is wrapped in quotes so it is treated as a literal (class-3).
Negative terms (e.g. `nipples, areola`) are declared by the scene, kept out of the image prompt, and
resolved per the wardrobe rung in effect (PRD 0007 B2, #109) — the default is freedom; a covering
scene must say so.

## Environment & runbook

| Thing | Where / how |
|---|---|
| Ruby | 3.4.5 via RVM (`source /usr/share/rvm/scripts/rvm && rvm use 3.4.5`) |
| The live app | growth-harness host on port **3004** (`bin/run_server.sh`), `RAILS_ENV=development` |
| Database | PostgreSQL (shared dev DB) |
| GPU | one RTX 4090 (24 GB), the two-tenant claim lifecycle above |
| Model staging | `/mnt/nas-ai-models/` (NAS) — brain GGUFs, LoRAs/checkpoints, the render corpus |
| Brain seat | `:8080` |
| Render corpus | the Sarah renders (backed up by `bin/corpus_backup.sh`) |
| Observability | Sentry (`config/initializers/sentry.rb`) |

**To run the harness end to end:** start the server (`bin/run_server.sh`), start the worker
(`bin/run_worker.sh`), and let the hourly posting rail + the nightly planner window run. Render and
caption work is driven by the harness itself; the brain seat is started on demand (scheduler-gated).

## Deploy

Kamal (`/tmp/tc-82/.kamal/` — `hooks/` + `secrets/`). The app is primarily operated as a
development-mode harness on the 4090 host rather than a pushed multi-node deploy; treat the live
tree on the 4090 as the system of record for day-to-day operation, with Kamal available for
reproducible deploys. The Cloudflare tunnel exposes the harness surfaces under `*.pi216.ai`.

## Backups

- **Render corpus:** `bin/corpus_backup.sh` writes a second copy off the primary and verifies it
  (a backup is not done until the copy is verified resolvable).
- **Cron fleet:** the profile keeps `ops/backups/cron_jobs_*.json` snapshots before fleet changes.

## Where reality diverges from this file

- **`bin/growth_harness.sh`** is intentionally dead — the live publisher is
  `bin/scheduled_posting.sh`. If you see a second hourly driver, that is a bug (the two-driver race).
- **The job substrate is Sidekiq only.** `solid_queue`/`solid_cache`/`solid_cable` are retired
  (PRD 0006 Q5 / #85); `bin/verify`'s `job_substrate` gate fails if a `solid_*` reference reappears.
- **The agent crons** live in the Hermes profile, not in this repo; `hermes cron list` is the
  authoritative view of the live fleet, and this table is a summary that must be reconciled against
  it.
