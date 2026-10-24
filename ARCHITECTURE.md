# ARCHITECTURE.md — turbo-carnival

> **Status:** CURRENT — the architecture home.
>
> **Provenance** — created 2026-10-21 for issue #82 (PRD 0006 F4). It is the "Architecture
> rails" pillar named in `FOUNDERS.md`. Before this file existed, the architecture truth was
> scattered across `AGENTS.md`, `docs/CONVENTIONS.md`, `docs/PIPELINE_SETUP.md` and the PRDs.
> Those topics now resolve here; the **operational** how-to resolves in `OPS.md`, the
> **behavioral/data contracts** (gates, commands, the claim contract, the test signal) resolve in
> `CONTRACTS.md`, and the **UI design system** resolves in `DESIGN.md`.
>
> This file is the *shape* of the system — structure and data flows — not the runbook. When
> prose and code disagree, the code wins; divergences are called out at the bottom of this file
> rather than left to drift.

## What this file owns (one truth per topic)

| Topic | Home |
|---|---|
| The app's structure: stack, pack boundaries, the command rail | **this file** |
| The render pipeline's role and data flow (not its validated values) | **this file** (validated config → `docs/baseline-config.md`) |
| The brain seat: what it is, where it runs | **this file** (its serving contract → `CONTRACTS.md`) |
| The growth harness: the day-to-day loop and the two-venue design | **this file** |
| The data spine: the model graph (shape only) | **this file** (the attribution-spine *contract* → `CONTRACTS.md`) |
| How to operate it: commands, cron, GPU, deploy | `OPS.md` |
| Behavioral/data contracts: gates, commands, claim, test signal | `CONTRACTS.md` |
| The UI design system | `DESIGN.md` |
| House rules, the authority ladder, the gate | `AGENTS.md` |
| The spine (workstreams, ordering) | `docs/PROJECT_PLAN.md` |

## Stack

| Layer | Technology |
|---|---|
| Framework | Rails 8 |
| Language / runtime | Ruby 3.4.5 (RVM) |
| Database | PostgreSQL |
| Background worker | **Sidekiq** 8.1 (the live queue substrate — see *divergences*) |
| Command rail | `gl_command` 2.0 (verb-first, rollback) |
| State machines | `state_machines-activerecord` 0.9 (string status columns) |
| Bounded contexts | Packwerk |
| Frontend | Tailwind CSS v4, ViewComponent, Hotwire |
| Observability | Sentry (`sentry-rails` / `sentry-ruby` / `sentry-sidekiq`) |
| Render engine | ComfyUI + ComfyUI-Manager (scheduler-gated) |
| Brain seat | Qwen3.8-27B-Uncensored-HauhauCS-Aggressive (GGUF, Q4_K_M) + mmproj vision, served by llama.cpp / HauhauCS FastMTP on `:8080` |

> The web server and the Sidekiq worker both run on the **4090 host** under RVM 3.4.5; the web
> server is the growth-harness host on port **3004**. See `OPS.md` for the runbook.

## Package boundaries (Packwerk)

The app is a set of bounded contexts under `packs/`, enforced by Packwerk (`bin/packwerk check`,
a member of the `bin/verify` gate — 0 violations). Each pack owns its own models/services/
commands; the root `app/` holds only cross-cutting shells (`application_record`, a few shared
models, `components`, `commands`, `views`).

| Pack | Owns |
|---|---|
| `attribution` | The data spine: the unbroken chain that links every published post to its photo, its pipeline run, its gate verdicts, and its persona. |
| `personas` | The `Persona` model (Sarah — the discovery-surface identity, 18 by fiat). |
| `content_pillars` | The persona's content pillars — the class-2 lever (reweight / retire / replace / add). |
| `content_strategy` | The strategy brain: campaigns, suggestions, gap-driven next-post selection. |
| `gap_analysis` | Content gap analysis over the persona's posting history. |
| `pipeline` | `PipelineRun` — a render run: the workflow, its variables, its lifecycle. |
| `comfyui` | The render-engine adapter: `ComfyuiJob`, `BuildJobPayload` (the single choke point that stamps `run_id`/`job_id` into the payload), the prompt-safety sanitize, the queue-first render path. |
| `caption_generation` | Captioning from the brain seat (the caption service + the brain client wiring). |
| `growth_harness` | The growth loop: `CadenceEngine`, `ContentGenerator`, `PersonaEvolution`, and the gates (`NsfwGate`, `RealismGate`, `PersonaAgeGate`, `BrainGate`, `NearDuplicateGate`, `SchedulerGate`, `GateRead`). |
| `job_orchestration` | Sidekiq job orchestration (`JobPollerWorker` — the only thing that advances `ComfyuiJob`/`PipelineRun` to a terminal status). |
| `scheduling` | The Instagram posting rail: immediate and scheduled posting through the Instagram Graph API. |
| `clustering` | Legacy content clustering (being removed — see `CLUSTER_REMOVAL_SUMMARY.md` in `docs/archive/`). |

## The command rail

Business logic lives in **GLCommand**s, not in controllers. Conventions (from `AGENTS.md`; the
pre-rebuild `docs/CONVENTIONS.md` is archived):

- Command class names start with a **verb** (`SendEmail`, `CreateUser`).
- Controllers do input validation and call a command; **no domain logic in controllers**.
- Commands declare `requires` / `returns`; a chain of commands rolls back in reverse order if any
  step fails.
- Isolated RSpec unit tests with GLCommand matchers; request specs cover auth + the correct command;
  a few integration specs for critical flows only. (The old guide referenced Pundit for auth — the
  app has no Pundit; it is a single-operator internal harness.)

## The render pipeline (shape)

The pipeline is a multi-stage ComfyUI workflow: a **pony base render**, then **flux face-inpaint** and
**flux hand-inpaint** passes, then an upscale. It is deliberately *not* deterministic (two
identical renders differ by ~4/255 over ~5% of the frame — a house trap). The structure:

- The **choke point** is `Comfyui::BuildJobPayload` — the single place the render-job payload is
  assembled. Token substitution (`{{prompt}}`, `{{auto_seed}}`, `{{timestamp}}`, …) and runtime
  variables are resolved here. The token system itself is documented in `OPS.md`.
- The **prompt-safety sanitize** wraps the image prompt in quotes so it is treated as a literal
  (class-3 explicitness is bounded by the legal floor, not by prompt-injection surface).
- A scene declares its own **negative** terms (e.g. `nipples, areola`) — kept out of the image
  prompt, resolved per the wardrobe rung in effect (PRD 0007 B2, #109).

> **The validated render configuration is a separate truth**: the exact checkpoints, sampler
> steps/denoise, identity block and scene live in `docs/baseline-config.md` (CURRENT, generated
> from the live workflow so it cannot carry a stale value). This file describes the pipeline's
> *role*; `baseline-config.md` is its *values*. Do not restate the values here.

## The brain seat

The local uncensored brain (PRD 0001) is a **data artefact, not a memory**: the model weights,
vision projection and serving config are recorded in `config/autonomous/brain.yml` and staged on
the NAS (`/mnt/nas-ai-models/LLM/gguf/…`). It is served on `:8080` by llama.cpp / HauhauCS
FastMTP and is **scheduler-gated** — it and ComfyUI share one 24 GB 4090 and are never
co-resident. The client is `lib/ai/brain_client.rb`.

- **What it does:** captioning and vision (the persona age-gate read, NSFW read) on the local seat.
- **How it is run:** `bin/brain_harness.sh` claims the GPU, serves, and releases (see `OPS.md`).
- **Its contract:** the serving-layer contract (degrades by value when unavailable, never a hard
  fail) is in `CONTRACTS.md`.

## The growth harness (the day-to-day loop)

`Growth::ContentGenerator` picks the next content (pillar rotation + the wardrobe rung), renders it
through the ComfyUI rail, captions it on the brain seat, runs the **gates**, and hands the asset to
the `scheduling` pack. `Growth::CadenceEngine` paces the posting to the measured platform
tolerance; `Growth::PersonaEvolution` reweights the content pillars (a class-2, bounded,
reversible change — see `AGENTS.md`).

**The two-venue design** (PRD 0007 / `docs/strategy-v2.md`): a **discovery surface** (Instagram,
the Sarah persona `a1.sarah.a1`) pushed to its *measured* platform tolerance, and a **permissive
payload venue** behind a second isolated persona. The discovery surface is live; the payload venue
is design intent, not yet built — do not describe it as implemented.

## The data spine (shape)

Every published post carries an unbroken chain, owned by the `attribution` pack:

```
Photo  →  PipelineRun  →  gates' verdicts  →  Persona  →  Post (posted_at)

Render  →  ContentConfigVersion   (the config the render ran under)
```

A `ContentConfigVersion` is the config as a first-class, **immutable** object: it pins the pillar,
the wardrobe rung, the checkpoint, the LoRA set, the negative, the workflow sha and the prompt
parts, and it is content-addressed by the digest of those pins. Editing the config writes a **new**
version — never an edit to an existing one — so a metric shift has an address.

Key models (pack-owned): `Photo`, `PipelineRun`, `ComfyuiJob`, `Post`, `Persona`, `ContentPillar`,
`ContentSuggestion`, `GapAnalysis`, `ContentConfigVersion`. The **attribution-spine contract** — what each link must carry
and why — is in `CONTRACTS.md`; this file only fixes the shape.

## Gates (summary)

The system has one **hard legal floor** (adult, no real-person likeness, synthetic mark) and a set
of **advisory measurements** (NSFW, realism). The floor gates fail closed; the advisory gates fail
open with a loud log and their scores are persisted on the asset. The full contract for each gate —
what it measures, its verdict, and its failure mode — is in `CONTRACTS.md`.

## Where reality diverges from this file

- **Queue substrate.** The substrate is **Sidekiq only** (`bin/run_worker.sh`, `JobPollerWorker`,
  `config/initializers/sidekiq.rb`); `solid_queue`/`solid_cache`/`solid_cable` are retired (PRD 0006
  Q5 / #85), and the `job_substrate` gate in `bin/verify` fails on a `solid_*` reference.
- **Render workflow name.** The validated config is `docs/baseline-config.md`
  (`comfy_workflows/turbo_one_step_v2/step1_generate.json`), generated from the live workflow.
  Older docs cite different node numbers/workflow names; **defer to `baseline-config.md`** for the
  current values.
- **`clustering` pack** is legacy and on the removal path; it is listed above for boundary
  completeness, not as an active surface.
