# The brain seat: where its serving data lives, and how it is measured

The local uncensored brain is served by llama.cpp on the 4090 under the same scheduler claim
discipline as ComfyUI. This file is the map for changing or debugging that seat; the class-level
llama.cpp behaviour (KV arithmetic, `--fit`, `--parallel`, MTP, mmproj) lives in the
`llama-cpp` skill, not here.

## Where the truth lives

| what | where |
|---|---|
| the artefact path + serving parameters (**the single home**) | `config/autonomous/brain.yml` |
| launch + claim lifecycle | `bin/brain_harness.sh` |
| harness log (launch args, claim transitions, exits) | `log/brain_harness.log` |
| the server's own log, per claim | `/mnt/nas-ai-models/gpu-scheduler/logs/brain-<job>.log` |
| claim state (job id, heartbeat pid, server pid, `origin`) | `log/brain_claim.json` |
| the seat's PRD and its resolved open questions | `docs/prd/0001-*` |

The per-claim server log is **append-only across relaunches inside one claim**, so it can hold
several loads; the newest `load_model` block is the running one. `origin=launched` means the
harness owns the process and may stop it; `origin=adopted` means it must not.

## Editing the serving config is a code change, not a config edit

`brain_serve_args()` emits a **fixed** argument list: model, host, port, `--n-gpu-layers`,
`--ctx-size`, `--cache-type-k/v`, `--batch-size`, `--ubatch-size`, `--flash-attn`, `--alias`,
`--no-warmup`. There is no plumbing for `--mmproj`, `--spec-type`, `--spec-draft-n-max`,
`--parallel`, or `--fit`.

So adding vision or MTP is always: a new key in `brain.yml`, a matching read in
`brain_serve_args()`, and a **measured** re-run. Both halves ship together or the yml lies about
what is running.

## `serving:` and `measured:` in the same file can disagree — check both

`brain.yml` carries a `serving:` block (what the harness will launch with) and a `measured:`
block (a matrix of configurations with the VRAM each actually cost). They are written by
different hands and can contradict each other.

- **A serving block that cannot fit does not fail loudly.** llama.cpp simply moves layers to the
  CPU and serves — at a fraction of the throughput. A silently degraded seat looks healthy.
- Verify what is *actually* loaded, not what the yml says: read the running command line
  (`pgrep -af llama-server`) and compare against the yml, then confirm with `/props`
  (`n_ctx`, `total_slots`, `modalities.vision`, `speculative.types`).
- Re-derive a hardcoded layer count against the current `measured:` entry and the card's live free
  VRAM. A count copied from a yml is an assumption about other tenants, and other tenants change.

## Measuring the seat

1. Confirm the card is free first (`nvidia-smi --query-gpu=memory.used,memory.free`; compare
   against the graphics contexts in the full process list). CUDA holds VRAM after a process
   exits, so a load issued while the previous server's memory is still resident understates what
   fits. Between loads, wait for the device reading — not for the port to close.
2. Read the harness log for the exact launch args and the claim transitions of that run.
3. Read the server log for the memory story: `allocating N MiB ... cudaMalloc failed` lines give
   the exact sizes that were attempted (these pin down the true KV bytes/token and how much VRAM
   was actually available).
4. Read `slot print_timing` lines for prompt-eval and decode rates; the seat has run as low as
   ~3.5 tok/s decode when layers sat on the CPU versus ~15 tok/s with more of the stack offloaded.
5. Query `/props` while it is up — it proves the loaded reality (context, slot count, whether
   vision is active, whether speculative decoding is on at all).

## Sizing context to the seat rather than to ambition

The seat is a planner. Check the **distribution of prompt sizes actually served** in the server
log before sizing context to a use case; a median prompt and a maximum prompt are different
requirements, and a context bought with CPU-offloaded layers is paid for on every token.

## Claim discipline (unchanged, restated because it is easy to break from here)

- Never start llama-server without a live claim. `bin/brain_harness.sh ensure` acquires;
  `stop-server` stops the process but **retains** the claim so the card is not lost between
  phases; `shutdown` releases it.
- An unclaimed server holding 22+ GiB makes the scheduler read the 4090 as idle — the
  false-idle double-book risk the harness exists to prevent.
- `stop-server` only stops a server the harness launched (`origin=launched`).
