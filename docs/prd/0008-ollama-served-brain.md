---
venture: turbo-carnival
source: PROJECT_PLAN
---

# PRD 0008 — The brain seat is served by Ollama

> **Status:** CURRENT · spec written 2026-10-24 · draft for founder review · waits on **Q1** (GPU policy: the seat's residency shape)
> Plan item: **W1.6** · Track: `core-infrastructure` · Owner: unassigned

## Summary

Move the **serving requirement** for the brain seat (PRD 0001) off `llama.cpp`'s `llama-server` and onto
**Ollama**, which on this box already serves the *same* weights — the same file, the same sha256 — as the
Ollama model `brain:latest`. The seat's own data (`config/autonomous/brain.yml`) stays the single source of
truth; the claim discipline does not move; the three llama.cpp-only serving features that have no Ollama
equivalent are recorded as *paid*, not glossed.

This PRD changes **who serves the seat**. It does not change the model, the phase machine, the gates, or the
legal floor.

## Problem / motivation

Numbered findings. Every one carries the command that produced it, run on **game** (the 4090 box) on
2026-10-24; none of them is a guess.

### F1 — "llama.cpp" is not a note in a document; it is the running tenant

The requirement is executed, not merely written: the harness launches a specific binary and the card is held
by it as this PRD is authored.

```bash
$ grep -n 'BRAIN_BIN=' bin/brain_harness.sh
54:BRAIN_BIN="${TC_BRAIN_BIN:-/home/tim/source/activity/llama.cpp/build/bin/llama-server}"

$ bash bin/brain_harness.sh deps
deps: llama-server OK — /home/tim/source/activity/llama.cpp/build/bin/llama-server
deps: artefact OK — /mnt/nas-ai-models/LLM/gguf/Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-Q4_K_P.gguf
deps: vision projector OK — /mnt/nas-ai-models/LLM/gguf/mmproj-Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-BF16.gguf
deps: speculative decoding configured — --spec-type draft-mtp (the model's own NextN head; no draft file)

$ bash bin/brain_harness.sh status
claim=busy job=brain-1792880733-2062946-1 ours=yes brain=up

$ nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader
2063125, /home/tim/source/activity/llama.cpp/build/bin/llama-server, 23106 MiB
```

So the engine is the binary path, the launch argument list, the tenant the claim covers, and the process
holding **23106 MiB** of a 24564 MiB card.

### F2 — Ollama already serves the same weights, and the identity is proven by hash

The Ollama model's manifest names layers whose sha256 are **byte-identical to the hashes `brain.yml` records**.
This is not "the same model by name"; it is the same bytes.

```bash
$ ollama show brain
  Model
    architecture        qwen35        Capabilities
    parameters          27.3B           tools
    context length      262144          thinking
    embedding length    5120            completion
    quantization        Q4_K_M          vision
  Projector
    architecture        clip          parameters  460.73M
    embedding length    1152          dimensions  5120
  Parameters
    min_p 0 · num_ctx 131072 · repeat_penalty 1 · temperature 1 · top_k 20 · top_p 0.95

$ cat /mnt/nas-ai-models/ollama/manifests/registry.ollama.ai/library/brain/latest
{"schemaVersion":2, … ,"layers":[
  {"mediaType":"…ollama.image.model",
   "digest":"sha256:ba36dc3c2b2ff5e0aa5d71092a8894546996a6a119ae391803dda07cdc08516d",
   "size":17923393664,"from":"Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-Q4_K_P.gguf"},
  {"mediaType":"…ollama.image.projector",
   "digest":"sha256:5681b690bcb8eb10cd28d62d078cb4e01521a3ea4880a3fc7d54de72de2dd142",
   "size":931146624,"from":"mmproj-Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-BF16.gguf"},
  {"mediaType":"…ollama.image.params","size":88}]}
```

| | brain.yml | Ollama manifest layer |
|---|---|---|
| `artefact.sha256` / `size_bytes` | `ba36dc3c…c08516d` / 17,923,393,664 | `sha256:ba36dc3c…c08516d` / 17,923,393,664 |
| `vision.sha256` / `size_bytes` | `5681b690…de2dd142` / 931,146,624 | `sha256:5681b690…de2dd142` / 931,146,624 |

The two blobs are on disk, content-addressed, at the recorded sizes:

```bash
$ ls -l /mnt/nas-ai-models/ollama/blobs/sha256-ba36dc3c… /mnt/nas-ai-models/ollama/blobs/sha256-5681b690…
-rw-r--r-- 1 1024 users   931146624 Oct 23 11:25 sha256-5681b690…de2dd142
-rw-r--r-- 1 1024 users 17923393664 Oct 23 11:25 sha256-ba36dc3c…c08516d
```

Arithmetic, so it can be checked rather than trusted: `17,923,393,664 + 931,146,624 = 18,854,540,288`, and
`/api/tags` reports `brain:latest` at **18,854,540,494** bytes — the two artefacts plus 206 bytes of
parameters/metadata. The capability set (`tools / thinking / completion / vision`) is the seat's full remit,
including the vision read the age gate (PRD 0007 B1) depends on.

**What is NOT proven by any of this:** that `num_ctx 131072` *fits and is placed on the 4090*. The model was
smoke-tested CPU-only (`vram=0`) in a sibling project; no GPU load has ever been placed under Ollama here.
See F5.

### F3 — the wrap is not a superset: three llama.cpp serving features have no Ollama equivalent

Paid deliberately, and named so no reader treats a number as a regression in the model:

| llama.cpp / `brain.yml` | Ollama | consequence |
|---|---|---|
| `serving.spec_type: draft-mtp` + `spec_draft_n_max: 3` (the model's own NextN head) | **no equivalent** | decodes without speculation. `brain.yml`'s measured **51.8 t/s** text / **58.8 t/s** vision are with-MTP numbers and do not transfer |
| `vision.offload: cpu` (`--no-mmproj-offload`) | **not settable** | Ollama decides where the projector runs; the 888 MiB that aborted the 2026-10-19 launch is no longer under our control |
| `vision.min_tokens: 1024` (`--image-min-tokens`) | **not settable** | Ollama picks its own minimum per architecture; the grounding minimum llama.cpp asks for at load is not addressable |
| `serving.cache_type_k/v: q8_0` | `OLLAMA_KV_CACHE_TYPE` — **server env, not a Modelfile parameter** | see F5 |
| `serving.parallel: 1` | `OLLAMA_NUM_PARALLEL` — **server env** | see F5 |
| `serving.n_gpu_layers: 65` | *omitted on purpose* | Ollama's scheduler estimates the fit itself; forcing 65 fails on a busy card instead of degrading |

Two gains worth recording: `tools` is a declared capability of the Ollama model that the seat's client never
asks for today (`BrainClient` sends no `tools`), and an Ollama model is content-addressed — the *identity* of
what is served becomes checkable, which it currently is not.

### F4 — the daemon that actually answers is unmanaged, and the unit is crash-looping

This is the finding with teeth. There are two Ollama server processes fighting for one port, and the managed
one is losing.

```bash
$ systemctl status ollama --no-pager | head -5
     Active: activating (auto-restart) (Result: exit-code) since Sat 2026-10-24 19:47:19 EDT
     Process: 2338425 ExecStart=/usr/local/bin/ollama serve (code=exited, status=1/FAILURE)
Oct 24 19:47:22 game systemd[1]: ollama.service: Scheduled restart job, restart counter is at 164432.

$ journalctl -u ollama --no-pager -n 3
game ollama[2339001]: Error: listen tcp 0.0.0.0:11434: bind: address already in use

$ ps -o pid=,user=,lstart=,cmd= -p 527519
 527519 tim      Thu Oct  8 14:12:47 2026 ollama serve

$ systemctl status 527519 --no-pager | head -2
● session-31.scope - Session 31 of User tim

$ ss -ltnp | grep 11434
LISTEN 0 4096 *:11434 *:* users:(("ollama",pid=527519,fd=4))
```

Read together: the systemd unit has restarted **164,432** times at `RestartSec=3` and has never bound the
port; the process that *is* serving `:11434` was hand-started on **2026-10-08**, is owned by `tim`, sits in a
transient **desktop login session** (`session-31.scope`, parent PID 1), and owns the listening socket. Its
environment carries **only** `OLLAMA_HOST` and `OLLAMA_MODELS`:

```bash
$ tr '\0' '\n' < /proc/527519/environ | grep -c '^OLLAMA'
2
```

so it has **no** `OLLAMA_FLASH_ATTENTION=1` (the unit sets it), **no** `OLLAMA_KV_CACHE_TYPE`, and **no**
`OLLAMA_NUM_PARALLEL`.

Two consequences, both already-named failure shapes in this repo:

- **The seat's daemon is outside systemd, outside the repo, and outside any GPU claim.** It holds 0 VRAM
  *right now* (`ollama ps` → `{"models":[]}`), but the first request against it loads ~17.6 GiB of blobs onto
  the 4090 with nothing covering the card — the same **false-idle double-book** risk
  `bin/comfyui_harness.sh` exists to prevent for ComfyUI, and which PRD 0001 made the brain harness's whole
  point.
- **A daemon tied to a login session is not a service.** It dies with the session, and nothing in this repo
  can start, stop, verify, or account for it. A seat whose server is a stranger's shell process cannot be a
  requirement.

### F5 — the KV setting the wrap needs to fit 131072 is absent, and the GPU placement is unmeasured

```bash
$ systemctl show ollama -p Environment
Environment=… OLLAMA_HOST=0.0.0.0:11434 OLLAMA_ORIGINS=192.168.86.103 http://* 
            OLLAMA_FLASH_ATTENTION=1 OLLAMA_MODELS=/mnt/nas-ai-models/ollama
```

Neither the unit nor the live daemon (F4) sets `OLLAMA_KV_CACHE_TYPE`. The wrap's own `Modelfile` states why
that matters — with `num_ctx 131072` and no `OLLAMA_KV_CACHE_TYPE=q8_0`, it *will not fit* a 24 GiB card. The
one GPU figure this repo owns is llama.cpp's (23,058 MiB footprint, 464 MiB free at `/health`); the Ollama
placement is **unmeasured**, and the card is 23,692 MiB busy with the llama.cpp seat while this is written, so
it cannot be measured now.

### F6 — the seat is 29 files, not one call site

```bash
$ grep -rl -E 'brain_harness|brain\.yml|BrainClient|brain_unclaimed|BrainGate|phase_handoff' \
    --include='*.rb' --include='*.sh' --include='*.yml' --include='*.py' --include='*.md' \
    app lib packs bin scripts config spec docs OPS.md ARCHITECTURE.md CONTRACTS.md | wc -l
29
```

| role | files |
|---|---|
| lifecycle / claim | `bin/brain_harness.sh` · `bin/brain_checkin.sh` · `bin/brain_plan_nightly.sh` · `bin/phase_handoff.sh` (+ its test) · `packs/growth_harness/…/growth/phase_handoff.rb` |
| clients / callers | `lib/ai/brain_client.rb` · `packs/caption_generation/…/{generator,model_config,vision_probe}.rb` · `packs/gap_analysis/…/suggester.rb` · `packs/growth_harness/…/{brain_gate,nightly_planner}.rb` · `app/commands/post_automation/generate_caption.rb` · `app/controllers/scheduling/posts_controller.rb` · `packs/growth_harness/app/models/growth/decision.rb` |
| data | `config/autonomous/brain.yml` |
| specs | 8 files under `spec/` |
| docs | `OPS.md` · `ARCHITECTURE.md` · `CONTRACTS.md` · `docs/prd/0001-*` · `docs/prd/0007-*` |

Two of those reads are engine-specific and will silently mis-report after a switch:

- `AI::BrainClient#available?` probes **`/health`** — a `llama-server` endpoint. Ollama serves `/api/version`,
  `/api/tags`, `/api/ps`. Pointed at Ollama unchanged, `available?` returns `false` forever and the seat reads
  as **down while it is up** — and every caller in the table above degrades on that answer.
- the thinking switch is engine-specific: `BrainClient` sends `chat_template_kwargs: { enable_thinking: false }`
  (llama.cpp's shape); Ollama's native switch is `"think": false` per request. A planner that gets a
  `reasoning_content` trace and an empty `content` raises `empty response from brain`.

### F7 — the Ollama seat is built by a project this repo does not own

The build lives in a **sibling directory**: `/home/tim/source/activity/brain-ollama/` (`Modelfile`,
`bin/build.sh`, `bin/probe.py`, `README.md`). Its README is explicit that it is a secondary project:
*"This is a secondary project, not a replacement… Nothing here is imported by the Rails app, and deleting this
directory does not change the harness's behaviour."*

But `brain.yml`'s own header claims the opposite boundary for the seat: *"This file is the single home for the
seat's data: the harness (#24) reads it and the serving parameters live under `serving`, not in a second
file."* If Ollama becomes the requirement while the build that produces `brain:latest` lives in an unlisted
directory outside the repo, then **the seat's definition is not in the repo** — and a next agent cannot
rebuild or verify it from this checkout.

### F8 — the switch doubles the seat's bytes on the same NAS

Ollama stores blobs by content digest and cannot reference an external path, so `brain:latest` is a second
copy of the same two files, on the same volume:

| | path | bytes |
|---|---|---|
| the artefact `brain.yml` names | `/mnt/nas-ai-models/LLM/gguf/Qwen3.8-…-Q4_K_P.gguf` | 17,923,393,664 |
| the same bytes, content-addressed | `/mnt/nas-ai-models/ollama/blobs/sha256-ba36dc3c…` | 17,923,393,664 |

That is **~17.56 GiB duplicated** (the store also holds 2,096 other blobs across every model on the box; the
duplicate attributable to *this* seat is its own two layers). It is a deliberate cost, but it must be
recorded — and it is the reason Q4 asks whether the loose copy should be retired *after* the switch.

### F9 — "ollama" already means a *different* thing in this repo

`lib/ai/ollama_client.rb` is a live class pointed at `http://192.168.86.49:11434` serving `gemma3:27b` — the
**retired caption** Ollama, a different host, a different model, a different job. Ticket #103 retired it from
the caption path (`app/commands/post_automation/generate_caption.rb`: *"the Ollama client it used to load is
retired from this path"*), and `packs/caption_generation/…/model_config.rb` resolves the caption seat through
`AI::BrainClient`. So "move to Ollama" and "the Ollama client" are two unrelated things in this tree, and the
transition must not be read as reviving `AI::OllamaClient`.

## Goals / Non-goals

- **Goals**
  - The seat is served by the Ollama model `brain:latest`, under the **same claim discipline** the ComfyUI
    harness already imposes — a tenant never holds the 4090 without a live claim covering it.
  - The Ollama lifecycle is **owned**: unit-managed, claim-gated, verifiable, and not tied to a login session.
  - Parity is **measured**, not assumed: the capability matrix in F3 is re-derived on this card, including
    the throughput the MTP loss actually costs and whether `num_ctx 131072` is placed on the GPU.
  - The seat's definition is reproducible **from this repo** — the Modelfile, the build and the probe stop
    living only in a sibling directory.
  - No caller changes its meaning: the caption path, the age-gate vision read, the nightly planner and the
    check-in keep working, and a down seat still degrades by value.
- **Non-goals (explicit Out)**
  - **Out:** the model. Same file, same sha256 (F2). No new weights, no re-quant, no base-model work.
  - **Out:** the phase machine and the phase handoff (PRD 0001 owns them). The measured-free-VRAM gate, the
    one-claim-per-batch rule and `stop-server` semantics are unchanged — this PRD re-points them.
  - **Out:** any gate's verdict. The age gate, the NSFW read and the realism read are unchanged; the legal
    floor (PRD 0007 §1) is untouched and remains the one fail-closed gate.
  - **Out:** the retired caption Ollama (`AI::OllamaClient`, F9) — it stays exactly as it is.
  - **Out:** what the planner thinks. This PRD moves the seat, not the occupant.
  - **Out:** deleting `llama.cpp` from disk. The tree at `/home/tim/source/activity/llama.cpp` is not ours to
    remove; only this repo's *requirement* on it moves.

## Scope — In / Out

**In:** porting the seat's build into the repo (Modelfile + build + probe) · re-pointing
`config/autonomous/brain.yml` at the Ollama seat · an Ollama-shaped `AI::BrainClient` (probe, thinking switch,
vision part) · a claim-gated load/unload path replacing the `llama-server` launch · repairing the Ollama unit
(F4) · the offline parity gate · the measured parity run on the 4090 · updating the docs and the 8 specs that
read the seat.

**Out:** the phase machine, the gates, the floor, the retired caption Ollama, and any change to the render
side of the app.

## Boundary

| concern | owner | **not this PRD** |
|---|---|---|
| the seat's existence, the artefact, the phase machine, `stop-server` semantics | **PRD 0001** | this PRD only re-points *who serves* the seat |
| the legal floor, the advisory gates, the age band | **PRD 0007** | unchanged; the vision read keeps its meaning |
| the caption path's serving home and its degrade-by-value contract | **#103** / `CONTRACTS.md` | unchanged — only the engine behind `AI::BrainClient` moves |
| the retired caption Ollama (`AI::OllamaClient`, `:11434` on `192.168.86.49`) | existing code | explicitly out (F9) |
| the GPU scheduler and its FIFO | `gpu_scheduler.py` / the `gpu-scheduler` skill | consumed, never modified |

## Acceptance criteria

Behaviour, in Gherkin notation. Per the repo's two-layer rule (`docs/prd/README.md`), the harness/shell and
Python scenarios are **definitions** — they are exercised by that tooling's own suite, never executed in Ruby.
Only the Rails-application scenarios become `.feature` files under `gherkin_specs/`.

```gherkin
Scenario: the seat is served by Ollama, not by a llama.cpp binary
  Given the harness's dependency surface
  When bin/brain_harness.sh deps is run
  Then it reports the Ollama seat (server reachable, model present, projector present)
  And it does not report a llama-server binary path
  And a missing or unreachable Ollama reports FAILED with a non-zero exit

Scenario: the seat is never loaded without a live claim
  Given no GPU claim is held
  When the harness is asked to ensure the seat
  Then it exits 2 and loads nothing
  And the refusal appears as a brain_unclaimed decision row
  And the 4090 holds no brain-model allocation afterwards

Scenario: a claim held by us is released with the model, not left resident
  Given we hold a claim and the brain model is resident
  When the nightly window ends
  Then the model is unloaded and residency is verified from the device
  And the claim is released
  And a later ollama ps shows no brain model

Scenario: an up seat is not read as down
  Given the Ollama seat is answering
  When AI::BrainClient#available? probes it
  Then it returns true
  And when the seat is not answering it returns false
  And neither answer blocks the caller

Scenario: the seat returns a plan rather than a reasoning trace
  Given the Ollama seat is up
  When a planning role asks for a scene/wardrobe spec with thinking off
  Then the answer arrives in content
  And no reasoning trace is returned as the answer
  And a legal in-lane brief is not refused or moralised

Scenario: the vision read still reads the frame
  Given the Ollama seat is up and holds its projector
  When the age gate asks for a read of a known frame
  Then the reply describes what is actually in frame
  And an unreadable read still leaves the gate unmeasured (fail-open), never a verdict

Scenario: the seat's identity is checkable
  Given the seat's data file records the artefact and projector sha256
  When the offline parity gate runs
  Then it fails if the seat's build names a different artefact than the data file
  And it fails if the harness's launch path names a llama.cpp binary
  And it passes with no GPU, no network and no Ollama

Scenario: a failed load is never reported as success
  Given the Ollama seat cannot load the model
  When the harness is asked to ensure it
  Then it reports the failure and exits non-zero
  And it never reports the seat as up
```

## User stories / job-to-be-done

- As **the Director**, I want the seat's daemon to be a service the repo owns, so that a login session ending
  cannot take the seat down and a stranger process cannot hold the 4090 unclaimed.
- As the **Thinker**, I want the same weights behind an endpoint that is stable, so a serving-engine change
  does not change what I plan.
- As the **Reviewer/age gate**, I want the vision read to keep reading the frame, so the floor's measurement
  does not silently become fluent nonsense.
- As a **next agent**, I want the seat rebuildable and verifiable from this checkout, so I do not have to
  discover a sibling directory to understand what is being served.

## Capability matrix — the price, stated

| feature | llama.cpp seat (today) | under Ollama | disposition |
|---|---|---|---|
| weights | Q4_K_P gguf, path-addressed | identical bytes, digest-addressed (F2) | **parity, improved** |
| vision projector | BF16 mmproj, second file | second `FROM`, embedded in the model | **parity** |
| context | 131072, q8_0 KV | 131072 **only with** `OLLAMA_KV_CACHE_TYPE=q8_0` | **parity, conditional** (F5) |
| speculative decode (MTP) | on, own NextN head | absent | **loss** — throughput re-measured |
| `--parallel 1` | pinned | `OLLAMA_NUM_PARALLEL` (env) | **parity, conditional** |
| `--flash-attn on` | on | `OLLAMA_FLASH_ATTENTION=1` (env) | **parity, conditional** |
| projector device | forced CPU (the launch that survived) | Ollama decides | **loss of control, re-measured** |
| `--image-min-tokens 1024` | set | absent | **loss** (Ollama's own minimum) |
| thinking off | `chat_template_kwargs` | `"think": false` | **parity, different wire** (F6) |
| tool calling | unused by our client | declared capability | **gain** |
| model identity | a path; nothing verifies the bytes at load | sha256 digest, checkable | **gain** |
| process ownership | harness-launched transient unit | a shippable systemd service | **gain** |

## Edge cases & red lines

- **A tenant never holds the card without a claim.** Unchanged from PRD 0001 and non-negotiable: an Ollama
  model left resident with no claim makes the scheduler read the 4090 as idle — the double-book failure the
  harness exists to prevent. **The claim must cover model residency, not merely process existence**, because
  Ollama's daemon is idle at 0 VRAM and only the *model* occupies the card.
- **An unmanaged daemon is not a seat.** F4 must be resolved before anything else is built on it: a server
  that lives in a login session cannot be a dependency.
- **`stop-server` changes meaning, and must keep its meaning.** Under llama.cpp it SIGTERMs a process; under
  Ollama the correct action is to *unload the model* while the daemon stays up. The phase handoff's contract
  (outgoing tenant verified down, then measured free VRAM) must keep reading the device, never the unload's
  exit code.
- **NULL ≠ false, and unmeasured ≠ down.** A seat that cannot be measured is not a seat that is absent. The
  probe's failure mode must stay fail-closed for the claim and fail-open (degrade by value) for the callers.
- **A failed load must never be reported as success.** The harness's existing rule, restated because the
  failure mode here is a *silent* CPU fallback: Ollama will happily serve a partially-offloaded model at a
  fraction of the throughput. The seat's placement must be read from `ollama ps` (`PROCESSOR` must not be
  `100% CPU`), not inferred from a 200.
- **Never kill or reconfigure a foreign tenant** — including the hand-started daemon of F4. Bringing `:11434`
  under management is a founder-visible infrastructure action; it must be an owned, recorded step, not an
  opportunistic `kill`.
- **No exfiltration.** The seat's build, hash and probe stay in this repo and on the owner's hosts
  (`AGENTS.md` § the content contract).
- **One truth per topic.** The switch lands with the llama.cpp launch path **removed from the requirement**,
  not left beside it. Two live serving paths under one name is the drift the repo's doc rules exist to stop.

## Metrics / definition of done

Every line maps to an enforced gate. Two lines name numbers; both name their emitted metric.

| # | done line | enforced by |
|---|---|---|
| D1 | the seat is served by Ollama — `deps` reports the Ollama seat and no llama-server path | a `--check`-able `bin/brain_harness.sh deps`, asserted by a spec |
| D2 | the seat's identity is checkable offline: the build names the same artefact + projector hashes as `brain.yml` | a new offline gate (`bin/check_brain_seat.rb`), an `bin/verify` member, fail-closed on a missing tree |
| D3 | a claim is required to load the model; the refusal is a `brain_unclaimed` decision row | `Growth::BrainGate` + the existing check-in cron |
| D4 | the model is unloaded and the card visibly freed at window end | the harness's unload step, evidenced by `ollama ps` and a device read in `log/brain_harness.log` |
| D5 | the probe answers correctly against Ollama (up ⇒ true, down ⇒ false) | `spec/services/ai_brain_client_spec.rb` |
| D6 | a planning role runs against the Ollama seat in a real nightly window | `rake brain:plan` writes suggestions (the PRD 0001 definition of done, re-pointed) |
| D7 | the age-gate vision read still grounds against a known frame | a recorded read-back in the ticket evidence, plus the gate's own fail-open spec |
| D8 | **number:** the seat's decode rate under Ollama is measured and recorded next to the 51.8 t/s it replaces | emitted by the seat probe and written into `log/brain_harness.log` / the ticket evidence — *measurement gap to name: this repo has no dashboard for it; the record is the log and the PRD* |
| D9 | **number:** `num_ctx 131072` is placed on the GPU, not silently offloaded | `ollama ps` (`CONTEXT` and `PROCESSOR` columns) read at the first real load — *measurement gap to name: no automated assertion exists; the reading is manual* |
| D10 | no caller's meaning changed: the caption path, the age gate and the planner behave as before, or their degradation is recorded | `bin/verify` (lint, packwerk, rspec, cucumber) |

## Open questions

1. **The seat's residency policy — GPU policy, so the founder's call.** May the brain model be left resident on
   the 4090 between windows (fast first answer, card held), or must the harness unload it at the end of every
   window (the current invariant: no tenant without a claim)?
   **Lean: unload at window end.** The seat is nightly and pull-based; nothing waits on it, and the double-book
   risk is the one thing PRD 0001 exists to prevent. Leaving it resident would make the scheduler's view of
   the card untrue, which is the failure shape this repo has already paid for twice.
2. **What throughput fails the transition?** The MTP loss is real and unbounded until measured (F3/F5). The
   seat must answer a vision request inside its own `serving.timeout_s`, or every caption degrades to
   `brain_unavailable`.
   **Lean: measure first, then set the number.** Provisional gate — a single vision request completes inside a
   timeout set from the measurement, and the recorded decode rate is not so far below 51.8 t/s that the
   nightly window cannot finish. *Who rules: the measurement (the system); the recorded number is the
   evidence, not a preference.*
3. **Is the seat's build owned by this repo?** F7 — today it is not, so the seat's definition is not in the
   tree that claims to be its single home.
   **Lean: yes, port it in** (`config/autonomous/ollama/Modelfile` + a build script + the probe, with
   `bin/check_brain_seat.rb` as the gate that keeps the Modelfile and `brain.yml` in agreement). A sibling
   directory may remain as a convenience, but nothing load-bearing may live only there.
4. **Do we keep the loose GGUF at `LLM/gguf/` after the switch?** F8 — ~17.56 GiB duplicated on one volume.
   **Lean: keep it.** It is the artefact `brain.yml` names and the thing every hash in this PRD is verified
   against; deleting it would remove the reference copy to save space on a NAS that is not reported as full.
   Record both homes and their sha256 in `brain.yml` so the duplication is deliberate and visible.

---

Drift note (gherkin-specialist): record every deviation when translating the Rails-app scenarios into
`.feature` files. Anything here that cannot be observed is not an acceptance criterion — it is a wish, and the
wish goes in `PROJECT_PLAN.md` instead.
