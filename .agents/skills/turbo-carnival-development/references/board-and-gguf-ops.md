# Board + GGUF ops (turbo-carnival)

Two jobs the repo's own tooling does not cover: moving a ticket on the board, and telling what a
model file actually is.

## Driving the board — there is no repo tooling

`rake plan:check` / `plan:index` do **not** exist (PRD 0003), and there is no `bin/board`. Do not go
looking. Every id you need is in `config/autonomous/pipeline.yml`:

- `project_id` = `PVT_kwDOE00cLc4BnqRm` (org `pi-216`, project 5)
- `status_field_id` = `PVTSSF_lADOE00cLc4BnqRmzhmNz0I`; options: todo `f75ad846`, in_progress `47fc9ee4`,
  done `98236657`

Resolve an issue to its project item id, then set the status:

```bash
# item id for each issue number
gh api graphql -f query='{ organization(login:"pi-216"){ projectV2(number:5){ items(first:100){
  nodes{ id content{ ... on Issue { number } } } } } } }'

# set status
gh api graphql -f query='mutation($p:ID!,$i:ID!,$f:ID!,$o:String!){
  updateProjectV2ItemFieldValue(input:{projectId:$p,itemId:$i,fieldId:$f,
  value:{singleSelectOptionId:$o}}){ projectV2Item{ id } } }' \
  -F p=PVT_kwDOE00cLc4BnqRm -F i=<ITEM_ID> \
  -F f=PVTSSF_lADOE00cLc4BnqRmzhmNz0I -f o=98236657
```

**Trap — `-f` vs `-F` for the option id.** The single-select option id must go through `-f` (raw
string). `-F` parses an all-digit value as a number, and the mutation dies with
`Could not coerce value 98236657 to String`. The `ID!` variables are safe with `-F` because they
contain letters.

**Rule — the `approved` label is the product owner's gate.** Set it only on the founder's explicit
instruction, never on your own judgement. `founder_needed` is a different thing: it means only the
founder can (a ruling, a credential, a platform setting, a GPU policy, a physical action). Never
overload one for the other.

**Rule — read back after every write.** `gh issue view <n> --json state,labels` plus a project query for
the status field. A mutation returning an item id is not evidence the field changed.

## Identifying a model artefact — the filename lies

`…-Uncensored-…` in a filename is a *claim*, not a fact. Read the GGUF metadata. `general.name`,
`general.finetune` and `general.tags` are what decide:

- `general.name = "Abl 27b"` → an abliterated tune.
- `Qwen3.8-27B-UD-*` → **an Unsloth Dynamic quant of the stock Qwen3.8-27B** (`general.name =
  Qwen3.8-27B`, no `uncensored` tag). It is the *hedging* model. Never substitute one for an
  uncensored seat — that re-imports the exact failure the local brain exists to fix.
- `general.tags` is the only place `vision` / `mtp` capability is declared.
- `general.file_type` gives the quant level: 15 = Q4_K_M, 17 = Q5_K_M, 18 = Q6_K.

This build has **no `llama-gguf`** — only `llama-cli` and `llama-server` — so parse the header directly.

**Trap — header alignment.** The GGUF header is `magic(4) version(4) tensor_count(8) kv_count(8)`.
Reading only `magic` and then two 8-byte fields misaligns by 4 bytes; every key read after that is
garbage and the parse dies with `EOFError` on the first key. Read all four fields.

**Trap — value width.** A value's type decides its width, and arrays (type 9) need element-type +
count then a per-element skip. Get one width wrong and the whole stream desynchronises.

## Staging a model onto the NAS — verify by hash, not by size

The brain's LLM area is **`/mnt/nas-ai-models/LLM/gguf/`**. `/mnt/models` is ComfyUI-only (`local_hot`:
checkpoints/loras/unet/vae/clip) — it has **no LLM area**. Do not stage an LLM there.

- **The mount on this box is NFS4** (`192.168.86.43:/volume1/ai-models`), *not* CIFS. The >1.7 GB CIFS
truncation trap does not apply on this path — but hash the copy anyway: a truncated copy reads as present
and a **size match proves nothing**. Stage, then `sha256sum` the copy and compare to the source
(`cmp`-level proof, not `ls -l`).
- **Timings (measured, 20.57 GiB):** `cp` over NFS ~3–4 min; the read-back `sha256sum` off the NAS ~5 min.
  Run both as background jobs (`terminal(background=true, notify=true)`) — do not block on them.
- **Add-only.** `/mnt/nas-ai-models` is shared: add, never overwrite or remove. The `gguf/` dir is
group-writable; a staged file lands owned `1024:users`, like its siblings.
- **Record the artefact as data** in `config/autonomous/brain.yml` — path + sha256 + size + GGUF metadata.
  That file is the seat's single data home; the harness (#24) reads the path from it and the serving
  parameters (#26) fill its `serving:` block. Do not create a second file for the same topic.

## The brain harness — `bin/brain_harness.sh`

The local uncensored brain (PRD 0001) served by llama.cpp, under the SAME file-based claim
discipline as ComfyUI. Mirrors `bin/comfyui_harness.sh`.

- Subcommands: `status` (`claim=<idle|busy|claimed> job=<id|none> ours=<yes|no> brain=<up|down>`),
  `ensure [--wait S]`, `heartbeat`, `shutdown`, plus offline `plan [FREE_MIB]` and `deps`.
- `ensure` mirrors ComfyUI: request→poll→activate, **adopt-or-launch** (an already-answering server is
  adopted, never doubled), exit 2 when it cannot hold a claim. It **never launches without an active
  claim** — the ordering is the invariant.
- **Artefact path + serving params come from `config/autonomous/brain.yml`** (one truth). Read it with
  **ruby** — `python3` has no PyYAML on this box. A bare `YAML.load_file` dies on the `staged_at:` Date
  and silently yields nil: use `YAML.safe_load(File.read(f), permitted_classes: [Date, Time], aliases: true)`.
- **Everything is env-overridable for offline tests:** `TC_SCHEDULER_PY`, `TC_SCHED_JOBS_DIR`,
  `TC_BRAIN_CLAIM_FILE`, `TC_BRAIN_LOG`. Point `TC_SCHEDULER_PY` at a fixture that always answers
  `not_my_turn` to prove the exit-2 refusal with no GPU and without touching the shared scheduler.
- **Full lifecycle test on an idle card:** `ensure` → `curl -s :8080/health` → a real completion on
  `/v1/chat/completions` → `shutdown` (port closed, GPU idle, claim released). `ensure` is fast because
  llama.cpp mmaps + `--no-warmup`; /health answers before a warm-up would.
- **Ruby-side live probe for client/resolver changes:** a scratch script at the worktree root run via
  `bin/rails runner 'load "tmp_probe.rb"'` — load the client + resolver, print the resolution, one text
  chat with a fixed echo prompt, one vision chat through the data-URL encoder path. `spec/fixtures` has
  no image fixtures; generate a small JPEG with ImageMagick (`convert -size 8x8 xc:red probe.jpg`).
  Delete the scratch probe before committing.
- `pgrep -f "llama-server.*--port 8080"` **false-positives** on any shell whose own command line contains
  that string — anchor the pattern on the binary path (`$BRAIN_BIN.*--port`).
- **Rails side:** `Growth::BrainGate` (mirrors `Growth::SchedulerGate`) reads `brain_harness.sh status`;
  `brain:checkin` (rake, via `bin/brain_checkin.sh`, cron every 15 min) records a `brain_unclaimed`
  `Growth::Decision` on an anomaly ONLY — ours-but-down (silent death) or up-with-no-claim (leak). A plain
  down-with-no-claim is the NORMAL idle state (the seat is transient) and must NOT row — a check-in that
  rows on every idle tick floods the ledger `growth:weekly_review` reads for resource-blockage density.

## A GPU window job — the wrapper/service split

Anything that needs the 4090 for real work (a planner pass, a batch) — as opposed to a per-tick
gate — follows the same split, and that split is what keeps the work testable without a card:

- **The GPU-touching half is a thin shell wrapper** (e.g. `bin/brain_plan_nightly.sh`):
  `bin/brain_harness.sh ensure` (claim + seat) → the work → the harness stop **always**, even on
  failure, so the card is never left resident. A refusal (`vram_insufficient` / a busy card) is a
  NORMAL outcome: log it and `exit 0` — never fail the cron on a shared card.
- **Do NOT put `set -u` in a wrapper that sources RVM.** RVM's `scripts/support` dereferences an
  unset `_system_name`, so `source …/rvm` aborts the whole script (exit 1) and nothing after it runs —
  not even the log line. A wrapper dying instantly with `_system_name: unbound variable` is this;
  drop `set -u` rather than guarding the source.
- **A cron job has no user systemd bus.** The harnesses launch through `systemctl --user` /
  `systemd-run --user`, so run straight from cron they fail with `Failed to connect to bus` and the
  job silently no-ops (the card is never touched — the night just never happens). Export
  `XDG_RUNTIME_DIR=/run/user/$(id -u)` and `DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus`
  at the top of the wrapper. Prove it by running the wrapper with those two unset
  (`env -u XDG_RUNTIME_DIR -u DBUS_SESSION_BUS_ADDRESS …`) — that is what cron looks like.
- **The work itself is a service plus a thin rake task**, holding no GPU or claim state, so it is
  exercisable with stubbed clients and no card. Assert on what was PERSISTED (rows written, a
  `Growth::Decision`), never on stdout.
- **Record the producing seat** (endpoint/model read from `brain.yml`) on whatever the job writes, so
  an output can be traced to the window that produced it.
- **A recurring writer must be idempotent per WINDOW and dedupe its CONTENT.** A job that mints rows
  every invocation duplicates them the moment it runs twice — and a manual re-run to verify it is
  exactly how that is discovered, so the defect surfaces while you are proving the job works. Two
  guards, both needed: (1) a per-window key — skip a subject already planned today unless `FORCE=1`
  (key on the period, not on "already ran", so a crashed half-run is re-runnable); (2) drop a proposal
  whose normalized title already exists for that subject (any status) **and** one already written in
  the same batch. Dedupe must only SKIP — never mutate or delete a row a human has used or rejected.
- **Feed the prior outputs back into the prompt**, not just filter them after: pass the existing
  titles/keywords to the model so it avoids repeats at the source. Filtering alone leaves it spending
  its budget re-proposing ideas already on the board.
- **Ship a ticket's doc/plan tick on the same branch+PR as its code.** A bare `git push origin main`
  is a separate approval gate; when nobody is watching, that stalls and the plan row silently stays
  stale while the code has already merged.
- The crontab line is **documented in the wrapper, not installed by the repo** — installing it is the
  operator's call.

## The phase handoff — `bin/phase_handoff.sh` (#25)

The gate between the 4090's two tenants. `THINK -> stop brain -> read free VRAM from the device ->
RENDER` (and the mirror for JUDGE). It is invoked while a batch claim is held; it never takes or
releases the claim itself.

- **Freeness is a device reading, never an exit code.** CUDA holds VRAM briefly after a process
exits, so the gate polls `nvidia-smi --query-gpu=memory.free` and admits the incoming phase only when
that reading clears the floor. Never wire in a pid-gone or `kill`-rc check as "freed".
- **Residency is checked BEFORE the reading.** A resident outgoing tenant parks the handoff
(`park:tenant_resident`) even if the free number happens to clear the floor. A foreign tenant is
never stopped — it parks.
- **One claim covers the whole batch.** Swap tenant servers with each harness's `stop-server`
(claim + heartbeat retained), never `shutdown` (which releases). `stop-server` is ownership-checked
and verifies the port closed.
- Subcommands: `measure` / `check render|brain` (read-only admission) / `to-render` / `to-brain` /
`plan FREE_MIB FLOOR_GIB [up|down]` (pure, offline) / `status`. Exit codes: 0 proceed, 3 park, 4
device unreadable.
- **Test offline**, no GPU/claim: `bin/phase_handoff_test.sh` fakes `nvidia-smi` (sequence file) and
the tenant harnesses via `TC_BRAIN_HARNESS` / `TC_COMFYUI_HARNESS`, then asserts by exit code. Mirror
that pattern for any new gate — a refusal must be proved by rc, not by reading the script.
- Ruby side: `Growth::PhaseHandoff.check(phase:)` reads `check`, fails closed, and writes a
`vram_insufficient` `Growth::Decision` on a park (a refused batch is a normal outcome).

## Talking to the brain from Ruby — `AI::BrainClient` (#27)

The planners reach the local brain over llama-server's OpenAI-compatible API.

- `lib/ai/brain_client.rb`: endpoint + alias come from `config/autonomous/brain.yml`
  (`serving.endpoint` / `serving.alias`); `available?` is a short fail-closed /health probe;
  `generate` mirrors `AI::GeminiClient`/`AI::OllamaClient` so a role can swap clients.
- **`chat` is multimodal**: `images: [base64, …]` builds OpenAI-compatible `image_url` parts
  (`data:image/jpeg;base64,…`) attached to the FIRST `user` message only — the original text and any
  other messages are unchanged. The bytes must really be JPEG (normalize upstream) or the data-URL
  label lies.
- **Turn thinking OFF.** This seat is a reasoning model: with `chat_template_kwargs.enable_thinking`
  unset, `content` comes back EMPTY whenever `max_tokens` is spent on the trace
  (`finish_reason=length`), and `reasoning_content` is not the answer. Send
  `chat_template_kwargs: { enable_thinking: false }` — measured: answer present and immediate.
- `lib/ai` is NOT a Zeitwerk root (config/application.rb `autoload_lib(ignore: %w[… ai])`);
  load these files explicitly (`require Rails.root.join('lib','ai','brain_client')`).
- **`persona.caption_config` is a `Personas::CaptionConfig` OBJECT, not a Hash.** Any
  `.dig(...)` / `['topics']` on it raises. `GapAnalysisAi::Suggester#build_context` did this,
  so the planner silently fell back to template suggestions and never reached a model — a
  rescue-into-fallback hides this class of bug. Read config defensively and assert the AI
  path in a spec (set `caption_config` to the real object shape in the example).

## Qwen3.8-27B (`qwen35`) geometry — cached, do not re-derive

`qwen35`: 64 blocks, `full_attention_interval = 4` → **only 16 layers hold a KV cache**; the other 48
are SSM linear-attention with a **context-independent** state. `head_count_kv = 4`,
`key_length = value_length = 256`.

⇒ **KV = 64 KiB/token at f16** (32 KiB at q8, 16 KiB at q4).

So a 20.57 GiB Q6_K on a 24 GB card still affords **~25 K tokens at f16 KV** — the plan-plus-ledger
prompt is a few thousand. Context is *not* a constraint for these planners. Do not argue a quant choice
from context length, and do not argue it from VRAM headroom either: the phase machine keeps the brain
and ComfyUI from ever being co-resident, so freed VRAM is not usable by rendering.

## Changing the serving home — what follows, what does not

When a model's serving home moves (e.g., Ollama host → local brain), the serving path moves with it, but the readers do not:

- **The ops board (`bin/tc_ops.py`) is a monitor, not the serving path.** Its probes point at fixed endpoints; after a home move they keep measuring the old host. Retargeting them is a SEPARATE ticket unless the ticket's In list names `tc_ops.py` — re-read the In/Out list before widening scope, and list the stale probes as a deliberate exclusion in the PR body.
- **Current state:** caption + vision reads resolve brain-only via `CaptionGeneration::ModelConfig` (`AI::BrainClient`); `AI::OllamaClient` is retired from the path but kept on disk. The retired ladder's env knobs (`CAPTION_FALLBACK_*`, `CAPTION_KEEP_ALIVE`) are gone from the resolution code.
- **Before retiring a config knob (env var / yml key), grep outside the repo** for production setters: hermes cron ymls (`$HERMES_HOME/profiles/*/cron/*.yml`) and `/etc/systemd` units live outside the tree. A knob with no setter anywhere can be deleted with no warning hook; one with a setter is a behaviour change, not a cleanup.
