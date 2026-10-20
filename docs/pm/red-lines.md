# PM red lines — turbo-carnival

**Founder-owned. Agents never edit this file — they read it.**

The suggestion lane (`venture-suggestion-pass`) reads this as the *durable* layer of its
anti-rejection fence: anything listed below is never proposed, however strong the market
evidence looks. The other two fence layers are computed, not written here — every
`rejected` issue in this repo, and the prior PM reports in
`~/.hermes/profiles/turbo-carnival/cron/output/`.

## Ruled out forever (product)

- **One truth per topic.** Never propose a `v(N+1)` that sits alongside the old document.
  Supersede and strike through; do not average two conflicting CURRENT sources.
- **Production may never wait on an experiment.** An experiment may read production's
  outputs; the reverse is forbidden.
- **Removing an `experiments/` folder must not change production behaviour.** Any
  suggestion that would violate this is out.
- **An incomplete render set is never presented as a smaller N.**
- **No unrecorded edits to the pillar set** — retiring, replacing, renaming, splitting or
  adding a pillar is a founder act, never a "fair game" change.

## Binding constraints on what may be proposed

- Read `docs/README.md` (the status rules) first. Only `CURRENT` documents are
  authoritative; `REFERENCE` / `HISTORICAL` / `UNREVIEWED` / `SUPERSEDED` are not.
- **Never overload `approved` and `needs-founder`** — they are different gates.
- **Never commit secrets**, and never propose anything that would put a credential in the
  tree; scan before any push.
- **ComfyUI runs only while this repo holds a GPU claim** (`bin/comfyui_harness.sh`) —
  never propose an alternative launch path.
- Shared experiment machinery is promoted out of `experiments/` only once **two**
  experiments need it — never copied.

## Not yet ruled on

Absence from this file is **not** permission — it means the topic has not been ruled on yet.
