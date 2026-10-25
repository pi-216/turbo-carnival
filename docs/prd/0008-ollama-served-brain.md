---
venture: turbo-carnival
source: PROJECT_PLAN
---

# PRD 0008 — The brain seat is served by Ollama

> **Status:** CURRENT · spec written 2026-10-24 · draft for founder review · **Q1–Q4 all resolved** (founder rulings, 2026-10-24)
> Plan item: **W1.6** · Track: `core-infrastructure` · Owner: unassigned

## Summary

Move the **serving requirement** for the brain seat (PRD 0001) off `llama.cpp`'s `llama-server` and onto
**Ollama**, which on this box already serves the *same* weights — the same file, the same sha256 — as the
Ollama model `brain:latest`.

Per the founder's Q3 ruling, that Ollama is **shared, externally managed infrastructure**: this repo neither
builds the model nor runs the daemon. It **consumes** the seat, **verifies** that what is served is the seat
it requires, and **survives** the seat being absent. The seat's own data
(`config/autonomous/brain.yml`) stays the single source of truth for *what this repo requires of the seat*;
the claim discipline does not move; the llama.cpp-only serving features that have no Ollama equivalent are
recorded as *paid*, not glossed.

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

### F4 — the daemon we depend on is unmanaged, and under Q3 it is not ours

Two Ollama server processes are fighting for one port, and the managed one is losing.

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

$ tr '\0' '\n' < /proc/527519/environ | grep -c '^OLLAMA'
2
```

Read together: the systemd unit has restarted **164,432** times at `RestartSec=3` and has never bound the
port; the process that *is* serving `:11434` was hand-started on **2026-10-08**, is owned by `tim`, sits in a
transient **desktop login session** (`session-31.scope`, parent PID 1), owns the listening socket, and carries
**only** `OLLAMA_HOST` and `OLLAMA_MODELS` — so **no** `OLLAMA_FLASH_ATTENTION=1` (the unit sets it), **no**
`OLLAMA_KV_CACHE_TYPE`, and **no** `OLLAMA_NUM_PARALLEL`.

**Q3 ruled this is not a defect for this repo to repair — the Ollama service is shared, externally managed
infrastructure.** That does not make it irrelevant; it changes what the finding *is*. It is a **dependency
risk to record, report and survive**, not a bug to fix:

- **The seat we consume may not be the seat `brain.yml` describes.** The daemon holds none of the three env
  settings the seat needs (F5), and a daemon living inside a login session dies with that session.
- **So the repo's job is to verify and to degrade**, not to adopt. The identity and placement checks (D2, D9)
  are what make a mis-served or CPU-offloaded seat *visible* instead of fluent; the serving-layer contract
  (degrade by value, never a hard fail) is what makes its absence survivable. Both already exist — this PRD
  points them at the shared seat.
- **We report it, once, to the infra owner** — the login-session daemon and the stamped-out unit are the infra
  owner's call, and nothing in this repo should take an action against either.

### F5 — the KV setting the seat needs to fit 131072 is absent, and the GPU placement is unmeasured

```bash
$ systemctl show ollama -p Environment
Environment=… OLLAMA_HOST=0.0.0.0:11434 OLLAMA_ORIGINS=192.168.86.103 http://* 
            OLLAMA_FLASH_ATTENTION=1 OLLAMA_MODELS=/mnt/nas-ai-models/ollama
```

Neither the unit nor the live daemon (F4) sets `OLLAMA_KV_CACHE_TYPE`. The seat's own `Modelfile` states why
that matters — with `num_ctx 131072` and no `OLLAMA_KV_CACHE_TYPE=q8_0`, it *will not fit* a 24 GiB card. The
one GPU figure this repo owns is llama.cpp's (23,058 MiB footprint, 464 MiB free at `/health`); the Ollama
placement is **unmeasured**, and the card is 23,692 MiB busy with the llama.cpp seat while this is written, so
it cannot be measured now.

Under Q3 this is again the infra owner's setting, not ours — which is exactly why **D9 makes our side
observable**: we read `ollama ps` and record what the card actually got, rather than assuming the seat's
declared context is the context we are served.

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

### F7 — the seat's build is a sibling project, and Q3 makes that the boundary

The build lives in `/home/tim/source/activity/brain-ollama/` (`Modelfile`, `bin/build.sh`, `bin/probe.py`,
`README.md`). Its README states the intent plainly: it exists so that *"a **different** consumer — a second
project, a laptop, a plain `ollama run` — can use the same weights without taking the 4090 claim or learning
the harness."*

**Q3 asked whether this repo should adopt that build. Ruled: no — the seat is shared, externally managed
infrastructure.** So this is not a gap to close; it is the boundary of what this repo owns. Three consequences:

- **`brain.yml`'s claim narrows to what it can honestly own.** Its header says it is "the single home for the
  seat's data". Under Q3 it is the single home for **the contract this repo requires of the seat** — the
  artefact and projector hashes, the context, the timeout, the endpoint and the alias — and *not* for how the
  seat is built or run. That is a wording defect this PRD fixes rather than a design change.
- **Verifying what we consume replaces owning it.** The digest check currently lives in the sibling project's
  `build.sh`, which refuses to build on a hash mismatch — a guarantee we get only if that project runs *and*
  only if we own the build. Once it is shared infrastructure, the check has to live on **our** side, at
  ensure-time, against the running seat.
- **We cannot assume our declared settings are the served ones.** F4/F5 show the live daemon carrying none of
  the three env knobs the seat needs, so the placement and identity readings (D2, D9) are the only honest
  answer to "is the seat we are paying for the seat we asked for?"

### F8 — the switch doubles the seat's bytes on the same NAS (recorded, no action)

Ollama stores blobs by content digest and cannot reference an external path, so `brain:latest` is a second
copy of the same two files, on the same volume:

| | path | bytes |
|---|---|---|
| the artefact `brain.yml` names | `/mnt/nas-ai-models/LLM/gguf/Qwen3.8-…-Q4_K_P.gguf` | 17,923,393,664 |
| the same bytes, content-addressed | `/mnt/nas-ai-models/ollama/blobs/sha256-ba36dc3c…` | 17,923,393,664 |

That is **~17.56 GiB duplicated** (the store also holds 2,096 other blobs across every model on the box; the
duplicate attributable to *this* seat is its own two layers). **Q4 ruled this is not this repo's problem —
leave it.** Recorded here so a future agent reading "the same weights twice" does not go looking for a task:
both homes are shared-storage facts, and neither is turbo-carnival's to retire.

### F9 — "ollama" already means a *different* thing in this repo

`lib/ai/ollama_client.rb` is a live class pointed at `http://192.168.86.49:11434` serving `gemma3:27b` — the
**retired caption** Ollama, a different host, a different model, a different job. Ticket #103 retired it from
the caption path (`app/commands/post_automation/generate_caption.rb`: *"the Ollama client it used to load is
retired from this path"*), and `packs/caption_generation/…/model_config.rb` resolves the caption seat through
`AI::BrainClient`. So "move to Ollama" and "the Ollama client" are two unrelated things in this tree, and the
transition must not be read as reviving `AI::OllamaClient`.

## Goals / Non-goals

- **Goals**
  - The seat is served by the shared Ollama model `brain:latest`, under the **same claim discipline** the
    ComfyUI harness already imposes on our side — a load we cause never lands on the 4090 without a claim.
  - **The seat we consume is verified to be the seat we require**: identity (the recorded sha256) and
    placement (`ollama ps`) are read from the running seat, fail-closed, rather than assumed.
  - Parity is **measured**, not assumed: the capability matrix in F3 is re-derived on this card, including
    the throughput the MTP loss actually costs and whether `num_ctx 131072` is placed on the GPU.
  - **A seat we do not control is a seat we survive**: absent, mis-served or evicted mid-window, the callers
    degrade by value exactly as the serving-layer contract already requires.
  - No caller changes its meaning: the caption path, the age-gate vision read, the nightly planner and the
    check-in keep working.
- **Non-goals (explicit Out)**
  - **Out:** the model. Same file, same sha256 (F2). No new weights, no re-quant, no base-model work.
  - **Out:** the seat's build and its daemon — **shared, externally managed infrastructure** (Q3, F7). No
    `Modelfile` in this repo, no build script, no daemon lifecycle, no repair of the Ollama unit (F4).
  - **Out:** the artefact's storage and any de-duplication (Q4, F8).
  - **Out:** the phase machine and the phase handoff (PRD 0001 owns them). The measured-free-VRAM gate, the
    one-claim-per-batch rule and `stop-server` semantics are unchanged — this PRD re-points them.
  - **Out:** any gate's verdict. The age gate, the NSFW read and the realism read are unchanged; the legal
    floor (PRD 0007 §1) is untouched and remains the one fail-closed gate.
  - **Out:** the retired caption Ollama (`AI::OllamaClient`, F9) — it stays exactly as it is.
  - **Out:** what the planner thinks. This PRD moves the seat, not the occupant.
  - **Out:** deleting `llama.cpp` from disk. The tree at `/home/tim/source/activity/llama.cpp` is not ours to
    remove; only this repo's *requirement* on it moves.

## Scope — In / Out

**In:** re-pointing `config/autonomous/brain.yml` at the shared Ollama seat (and narrowing its header to the
contract it owns) · an Ollama-shaped `AI::BrainClient` (probe, thinking switch, vision part) · a claim-gated
**warm/verify/release** path replacing the `llama-server` launch · ensure-time identity and placement
verification against the running seat · the `serving.timeout_s` change (Q2) and its caller-budget consequence ·
the measured parity run on the 4090 · updating the docs and the 8 specs that read the seat.

**Out:** the phase machine, the gates, the floor, the seat's build, the daemon, the artefact's storage, the
retired caption Ollama, and any change to the render side of the app.

## Boundary

| concern | owner | **not this PRD** |
|---|---|---|
| the seat's existence, the artefact, the phase machine, `stop-server` semantics | **PRD 0001** | this PRD only re-points *who serves* the seat |
| the legal floor, the advisory gates, the age band | **PRD 0007** | unchanged; the vision read keeps its meaning |
| the caption path's serving home and its degrade-by-value contract | **#103** / `CONTRACTS.md` | unchanged — only the engine behind `AI::BrainClient` moves |
| **the Ollama daemon, its unit, its env, and the `brain:latest` build** | **the infra owner — shared, externally managed (Q3)** | explicitly out: consumed and reported, never repaired here |
| the artefact's two homes on shared storage | shared storage (Q4) | explicitly out: recorded, no action (F8) |
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

Scenario: the seat we consume is verified to be the seat we require
  Given the seat's data file records the artefact and projector sha256
  When the harness ensures the seat against the running Ollama
  Then it checks the served model's identity against those recorded hashes
  And on a mismatch the seat is NOT reported up, and the mismatch is reported loudly
  And the check is made against the running seat, not against a build this repo owns

Scenario: the seat's placement is read, never assumed
  Given the seat is up
  When its residency is inspected
  Then the context actually loaded and the processor actually used are read from the seat
  And a seat served entirely on CPU is reported as a degraded placement, not as up-and-well

Scenario: the seat is never loaded without a live claim
  Given no GPU claim is held
  When the harness is asked to ensure the seat
  Then it exits 2 and loads nothing
  And the refusal appears as a brain_unclaimed decision row
  And the 4090 holds no brain-model allocation caused by us afterwards

Scenario: a model that was already resident is left running
  Given the brain model is already resident when the harness arrives
  When the harness takes its claim and the window ends
  Then the model is NOT unloaded
  And this is recorded as an adopted residency, not a launched one
  And the claim is released without the model being stopped

Scenario: a model the harness had to start does not outlive its window
  Given the brain model was not resident
  When the harness loads it to serve the window
  Then the load carries no keep-alive
  And at the window's end the model is no longer resident
  And residency is verified from the device, never from an unload's exit code

Scenario: a shared seat can vanish mid-window and the caller still finishes
  Given the seat was resident and another consumer evicts it mid-window
  When a planning or caption call is made
  Then the call does not hang beyond its budget
  And a cold reload is permitted, because the request timeout is sized for one
  And if the seat cannot be recovered the caller degrades by value

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

Scenario: the repo takes no action against shared infrastructure
  Given the Ollama daemon is running outside this repo's control
  When the harness stops the seat
  Then it stops only a residency this repo launched
  And it never stops, restarts, reconfigures or kills the daemon itself
  And it never acts on the systemd unit

Scenario: a failed load is never reported as success
  Given the Ollama seat cannot load the model
  When the harness is asked to ensure it
  Then it reports the failure and exits non-zero
  And it never reports the seat as up
```

## User stories / job-to-be-done

- As **the Director**, I want our side of the shared card held correctly, so that a load we cause is always
  covered by a claim and we never blame shared infrastructure for our own unclaimed load.
- As the **Thinker**, I want the same weights behind an endpoint that is stable, so a serving-engine change
  does not change what I plan.
- As the **Reviewer/age gate**, I want the vision read to keep reading the frame, so the floor's measurement
  does not silently become fluent nonsense.
- As a **next agent**, I want to know exactly which half of the seat this repo owns, so I neither rebuild
  shared infrastructure nor assume shared infrastructure will be maintained for me.

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
| request timeout | 120 s | **600 s** (Q2) | **gain** — a cold load now fits |
| tool calling | unused by our client | declared capability | **gain** |
| model identity | a path; nothing verifies the bytes at load | sha256 digest, checkable | **gain** |
| build ownership | ours (a binary we launch) | **theirs — shared infra** (Q3) | **loss of control, deliberately** |
| daemon lifecycle | harness-launched transient unit | **not ours** (Q3, F4) | **out of scope** — a reported dependency risk |

## Edge cases & red lines

- **A load we cause never lands on the card without a claim.** Unchanged from PRD 0001 and non-negotiable: a
  model resident with no claim covering it makes the scheduler read the 4090 as idle — the double-book failure
  the harness exists to prevent. **Our claim covers a load we caused**, not the shared daemon and not other
  consumers' loads (Q3).
- **Residency follows ownership** (Q1). A model already resident when the harness arrives is **left running**;
  a model the harness had to start is loaded **without keep-alive**, so it does not outlive the window that
  needed it. Do not unload what you did not load.
- **Shared infrastructure is consumed, never repaired.** The Ollama daemon, its unit and its env (F4, F5) are
  the infra owner's. This repo reports the discrepancy once and moves on: no `systemctl`, no `kill`, no
  `OLLAMA_*` rewrite, no adopted-daemon fixes. A dependency we do not control is a reason to verify and
  degrade, never a licence to reconfigure someone else's service.
- **`stop-server` changes meaning, and must keep its meaning.** Under llama.cpp it SIGTERMs a process; under
  Ollama the correct action is to end **our** residency while the shared daemon stays up. The phase handoff's
  contract (outgoing tenant verified down, then measured free VRAM) must keep reading the device, never an
  unload's exit code — and the *idle expiry* is now part of that clock, not an instant.
- **NULL ≠ false, and unmeasured ≠ down.** A seat that cannot be measured is not a seat that is absent. The
  probe's failure mode must stay fail-closed for the claim and fail-open (degrade by value) for the callers.
- **A failed load must never be reported as success.** The harness's existing rule, restated because the
  failure mode here is a *silent* CPU fallback: Ollama will happily serve a partially-offloaded model at a
  fraction of the throughput. Placement must be read from `ollama ps` (`PROCESSOR` must not be `100% CPU`),
  not inferred from a 200.
- **A shared seat can leave mid-window.** Another consumer may evict our model — and under Q1 we must not
  re-adopt a stranger's residency as if it were ours. The caller's contract is unchanged: finish inside its
  budget or degrade by value; the request timeout (Q2) is what makes one cold reload affordable.
- **No exfiltration.** Seat hashes, probes and readings stay in this repo and on the owner's hosts
  (`AGENTS.md` § the content contract).
- **One truth per topic.** The switch lands with the llama.cpp launch path **removed from the requirement**,
  not left beside it. Two live serving paths under one name is the drift the repo's doc rules exist to stop.

## The residency rule — founder ruling (2026-10-24)

**Q1, resolved.** Recorded verbatim:

> *"if the model was running, keep it running. If it had to be started, it should have been started without
> keepalive"*

This is not a new concept — it is the **ownership rule PRD 0001 already applies to processes, extended to
residency.** The harness already records which side of that line it is on: `log/brain_claim.json`'s fourth
line is `origin=launched|adopted`, and `shutdown`/`stop-server` already refuse to stop an adopted server
(*"adopted instance … left running — not ours to stop"*). Residency takes the same field:

| | when | the rule |
|---|---|---|
| **adopted residency** | the model is already resident when the harness arrives | **keep it running.** The harness takes its claim, serves, and releases — it does not unload a model it did not load |
| **launched residency** | the model was not resident, so the harness had to load it | the load carries **no keep-alive**, so it does not outlive the work that needed it; the card is not left held by a load we created |

Consequences, so the next agent does not re-derive them:

- **Both halves are the same sentence.** Half one forbids killing a stranger's residency; half two forbids
  bequeathing our own. Neither is a preference about the card — it is the line between *mine* and *not mine*,
  which is exactly what `origin` already encodes.
- **`ollama ps` becomes the residency ledger**, and it is a better instrument than a pid: it names the resident
  model and its `size_vram` and `expires_at`.
- **This corrects the PRD's own first lean** (*"unload at window end"*). That lean was unconditional, and
  therefore wrong in the adopted case: it would have had the harness evict a model it did not start, which is
  the "never touch a foreign tenant" red line applied to residency. The ruling is *conditional on ownership*,
  and it is the better rule.
- **One implementation detail is left to the ticket, not the founder:** whether "no keep-alive" means a literal
  `keep_alive: 0` per request (which expires the model the moment the request finishes, and would force a cold
  load per request — ~17.6 GiB from NFS each time) or simply *omitting a pin* so `OLLAMA_KEEP_ALIVE` governs
  the idle window. The ticket **measures** which reading satisfies the ruling at acceptable cost; do not guess
  it here, and do not pin the model forever in either reading.
- **Truthfulness over tidiness:** after the window, `ollama ps` may legitimately still show the model — because
  it was adopted. An entry there is **not** by itself a leak; it is a leak only when no claim covers it.
  Reporting residency as a proxy for "we cleaned up" is the reading this rule forbids.
- **The ruling breaks the check-in's leak test as it stands — this is a defect, not a footnote.** Adopted
  residency makes *"model resident, claim released"* a **legitimate** end state, but the check-in currently
  treats exactly that as an anomaly: `brain:checkin`'s `(gate.ours && !gate.brain_up) || (gate.brain_up &&
  !gate.ours)` arm fires on `brain_up && !ours`, which is precisely the state an adopted window leaves behind.
  Shipped unchanged, every adopted window files a **false `brain_unclaimed` decision row**. So the harness
  must record adoption where the gate can read it (it already stores `origin=adopted` in
  `log/brain_claim.json`, but `Growth::BrainGate.parse` reads only `claim=/job=/ours=/brain=` off the status
  line, so the status line needs the residency owner in it), and the check-in becomes: resident + no claim
  **+ no adoption record** = leak. Getting this wrong turns a correct ruling into an alarm that cries every
  night — and a noisy alarm is one nobody reads when the real orphan appears.

## The serving timeout — founder ruling (2026-10-24)

**Q2, resolved: 10 minutes.** `serving.timeout_s: 600`, superseding the **120** recorded in `brain.yml` and the
`DEFAULT_TIMEOUT = 120` in `lib/ai/brain_client.rb`.

It is the right number *because of* the other three rulings, not independently of them: it is what makes a
**cold load survivable**. A launched window (Q1) starts with no resident model, so its first request pays a
17.6 GiB NFS read plus model init — minutes, not seconds. At 120 s that first request would fail and every
caption in the window would degrade to `brain_unavailable`; at 600 s a window can pay the cold-load cost once
and then answer warm. Under Q3 it also covers the eviction case: a shared seat can be dropped by another
consumer mid-window, and 600 s is what lets the next call re-load instead of failing.

Consequences, so the next agent does not re-derive them:

- **The timeout is a *request* budget, not a probe budget.** The short fail-closed probe stays short
  (`BrainClient::PROBE_TIMEOUT`, 3 s) and the harness's own `UP_WAIT` stays its own number. A long request
  timeout beside a long probe would make every caller wait ten minutes to learn the seat is down — the exact
  opposite of the degrade-by-value contract.
- **One number, read from one place.** `AI::BrainClient.config` reads `serving.timeout_s` and
  `packs/caption_generation/…/model_config.rb` resolves endpoint/model/timeout through it, so the caption path,
  the age gate and the planner cannot drift onto different values.
- **⚠ The caller budget is the open question this ruling exposes, and it is a *build* problem, not a ruling.**
  A 600 s request cannot be spent inside a tick that dies sooner — the harness has measured a foreground tool
  call SIGKILLed at **~420 s** and a 360 s producer budget. So a 10-minute timeout only means something if the
  call moves off the tick. The ticket resolves it (the Sidekiq substrate from PRD 0006 Q5 now exists, so a
  caption/plan call can be a job rather than an in-tick request) and records which caller can actually reach
  600 s. Setting the number without moving the caller would be a timeout nothing can ever use.

## Metrics / definition of done

Every line maps to an enforced gate. Three lines name numbers; each names its emitted metric.

| # | done line | enforced by |
|---|---|---|
| D1 | the seat is served by Ollama — `deps` reports the Ollama seat and no llama-server path | a `--check`-able `bin/brain_harness.sh deps`, asserted by a spec |
| D2 | **the seat we consume is verified to be the seat we require** — the served model's identity is checked against `brain.yml`'s recorded sha256, fail-closed | an ensure-time identity check in the harness + a spec with a mismatch fixture; `deps` prints the served digest |
| D3 | a load we cause requires a claim; the refusal is a `brain_unclaimed` decision row | `Growth::BrainGate` + the existing check-in cron |
| D4 | a model the harness **started** is not resident after its window; a model it **adopted** is left running | the harness's `origin=launched` / `origin=adopted` record plus `ollama ps`, and a device read in `log/brain_harness.log` |
| D5 | the probe answers correctly against Ollama (up ⇒ true, down ⇒ false) without blocking a caller | `spec/services/ai_brain_client_spec.rb` |
| D6 | a planning role runs against the Ollama seat in a real nightly window | `rake brain:plan` writes suggestions (the PRD 0001 definition of done, re-pointed) |
| D7 | the age-gate vision read still grounds against a known frame | a recorded read-back in the ticket evidence, plus the gate's own fail-open spec |
| D8 | **number:** the seat's decode rate under Ollama is measured and recorded next to the 51.8 t/s it replaces | emitted by the seat probe and written into `log/brain_harness.log` / the ticket evidence — *measurement gap to name: this repo has no dashboard for it; the record is the log and the PRD* |
| D9 | **number:** `num_ctx 131072` is placed on the GPU, not silently offloaded | `ollama ps` (`CONTEXT` and `PROCESSOR` columns) read at the first real load — *measurement gap to name: no automated assertion exists; the reading is manual* |
| D10 | no caller's meaning changed: the caption path, the age gate and the planner behave as before, or their degradation is recorded | `bin/verify` (lint, packwerk, rspec, cucumber) |
| D11 | the residency rule holds by ownership: an adopted model is never unloaded, and a resident model with no claim covering it and no adoption record is recorded as a leak | `Growth::BrainGate`'s `brain_up && !ours` arm + the check-in cron, re-pointed at `ollama ps` |
| D12 | **number:** the seat's request timeout is **600 s**, read from one place, with at least one caller that can actually reach it | `brain.yml` `serving.timeout_s` + `AI::BrainClient.config`, asserted by a spec; the caller-budget resolution recorded in the ticket |
| D13 | the repo takes no action against shared infrastructure: no `systemctl`, `kill` or `OLLAMA_*` write targets the daemon or its unit | a spec asserting the harness's command surface, plus code review (`AGENTS.md` PR gate) |

## Open questions

All four are resolved. Recorded in the order they were ruled.

1. ~~**The seat's residency policy** — GPU policy, so the founder's call.~~ **RESOLVED — founder ruling,
   2026-10-24:** *"if the model was running, keep it running. If it had to be started, it should have been
   started without keepalive."* Restated as the ownership rule for residency — adopted residency is left
   running, launched residency carries no keep-alive — in **§ The residency rule**. This supersedes the PRD's
   first lean (*"unload at window end"*), which was unconditional and would therefore have evicted a model the
   harness did not start.
2. ~~**What throughput fails the transition?**~~ **RESOLVED — founder ruling, 2026-10-24: a 10-minute
   timeout.** `serving.timeout_s: 600`, sized so a cold load fits, with the caller's own budget named as the
   build problem it is — see **§ The serving timeout**. This replaces the PRD's lean (a number derived from the
   measurement) with a founder-set ceiling; the measured decode rate (D8) is still recorded beside it.
3. ~~**Is the seat's build owned by this repo?**~~ **RESOLVED — founder ruling, 2026-10-24: no — "it is
   shared, externally managed infrastructure."** The build, the daemon and its env stay outside this repo; the
   repo consumes and verifies them. This reverses the PRD's lean (*"port it in"*), and it is why D2 moved from
   an offline gate over a repo-owned Modelfile to an **ensure-time check against the running seat**, and why F4
   is a reported dependency risk rather than a repair ticket. See F4 and F7.
4. ~~**Do we keep the loose GGUF at `LLM/gguf/` after the switch?**~~ **RESOLVED — founder ruling, 2026-10-24:
   "not this repos problem. Leave it."** F8 records the ~17.56 GiB duplication as a shared-storage fact with no
   action attached, so nobody re-opens it looking for a task.

---

Drift note (gherkin-specialist): record every deviation when translating the Rails-app scenarios into
`.feature` files. Anything here that cannot be observed is not an acceptance criterion — it is a wish, and the
wish goes in `PROJECT_PLAN.md` instead.
