# The local brain seat (PRD 0001) — data contract

The "brain" is the local uncensored model served by llama.cpp on the 4090, a separate tenant from
ComfyUI with its own scheduler-gated harness. This file maps where its configuration lives and which
code parses it. The SERVING physics — VRAM budgets, KV-per-token, MTP, vision, quant choice — lives
in the `local-llm-agent-serving` skill; do not restate it here.

## One data home

`config/autonomous/brain.yml` is the seat's data file: artefact path plus serving parameters. Do not
scatter these values into the harness, a cron prompt, or a prose table in a PRD — `docs/prd/0001`
points at this file for the numbers rather than repeating them.

Exactly two readers parse it. Grep before changing its SHAPE:

| reader | keys | note |
|---|---|---|
| `bin/brain_harness.sh` | `artefact.path`, `vision.path`, `serving.*` | renders the server argv |
| `lib/ai/brain_client.rb` | `serving.endpoint`, `serving.alias`, `serving.timeout_s` | covered by `spec/services/ai_brain_client_spec.rb` |

**Never rename or drop `serving.endpoint` / `alias` / `timeout_s`.** The Rails client is what
actually talks to the seat, and it falls back to its `DEFAULT_*` constants when a key is absent — so
a rename presents as "the brain is unreachable", not as a configuration error.

Label every number in that file measured or projected, and replace a projection with the measurement
in the same file once you have one. A block that reads as measured when nobody measured it is worse
than no numbers, because the next agent cites it as evidence.

## The harness is the only way to start the seat

`bin/brain_harness.sh` — never launch `llama-server` any other way. An unclaimed server makes the
scheduler read the card as idle while it is ~21 GiB busy, which is how the card gets double-booked.

Subcommands: `status`, `ensure [--wait S]`, `heartbeat`, `shutdown`, `stop-server`, `plan
[FREE_MIB]`, `deps`.

- **`plan` and `deps` are offline** — no GPU, no claim, no mutation. `plan` prints the exact argv
  `ensure` would use; `deps` checks the binary, the artefact and the projector. This pair is the dry
  run for a config change: the change is not done until `plan` shows the flags you intended.
- **`stop-server` stops the server and KEEPS the claim** — that is how you swap the served model or
  its parameters inside one batch without yielding the card.
- **`ensure` ADOPTS an already-answering server.** Editing `brain.yml` therefore changes nothing while
  the seat is up; it applies only after `stop-server`/`shutdown` then `ensure`. State which of those
  two states you are actually in instead of implying the new config is live.
- `TC_BRAIN_YML=<fixture>` overrides the config path — that is how the argv renderer gets tested
  against an older-format file without touching the real one.

## `status` is machine-parsed — append only

`Growth::BrainGate` (packs/growth_harness) shells out to `bin/brain_harness.sh status` and matches
`claim=(\S+) job=(\S+) ours=(\S+) brain=(\S+)`. That regex is **not end-anchored**, so new fields may
be appended at the END of the line. Inserting one in the middle silently breaks the gate, and a
broken gate fail-closes — it reads as "no brain claim", not as a parse error.

## Editing it in a live tree

`brain.yml` and the harness are edited in a checkout other writers also hold, so keep the diff to
those files and expect a rewrite to be refused until you have re-read the current content. To produce
a reviewable PR that excludes another writer's uncommitted work without switching branches, use the
shared-dirty-tree recipe in `github-pr-workflow` §1.
