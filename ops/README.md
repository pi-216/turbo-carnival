# ops/ — the fix loop

Monitoring in this repo detects problems (harness logs, GPU-scheduler state, cgroup
telemetry, cron output, Rails data). This directory is where a detection becomes a
**tracked, closable work item**, so the same failure is not re-diagnosed from
scratch every few days.

| path | what it is |
|---|---|
| `board/<key>.json` | one issue per STABLE key; repeated probes refresh the same file, never duplicate it |
| `board/archive/<key>.jsonl` | note history trimmed out of the live record (archived, never deleted) |
| `NEEDS_HUMAN.md` | **generated** — markdown digest of every open item, split by `route`, written by `bin/tc_ops.py probe` |
| `systemd/`, `backups/` | unit files and repo backups for this loop |

## Start here

```bash
python3 bin/tc_ops.py list          # open items, by severity, with route
python3 bin/tc_ops.py show <key>    # full record: evidence, notes, provenance
python3 bin/tc_ops.py escalations   # ONLY what needs Tim (empty = nothing)
cat ops/NEEDS_HUMAN.md              # the same board as a readable digest
```

`tc-ops-triage` (Hermes cron, hourly) runs `probe`, works the open items, and
commits the board. `bin/tc_ops.py selftest` asserts the pure decisions the board
depends on — run it after touching the checks.

## Route: whose call is it?

Every open item carries a `route`, and the split is the point. A board whose every
item is "needs a human" is a board with no decision-maker: each hourly pass
re-derives the same deferred item, appends a note, and closes nothing.

- **`route=agent`** (default) — a business/product call the **operating agent
  owns**. Decide it and close it with the decision as the note. Routing one of
  these to a human is the failure mode, not diligence.
- **`route=tim`** — **enablement only**: something no agent can do from here (a
  file outside this repo, a credential, a channel/platform setting, a GPU policy).
  These are the only items an escalation job may push to the operator.

```bash
python3 bin/tc_ops.py route <key> --route tim -n '<why it needs a human>'
```

## Conventions

- `source=probe` — the probe owns the key: it re-files while the condition
  reproduces and auto-closes it when it stops. Closing one by hand does not stick.
- `source=manual` — filed by an agent or by hand (an outside-scope problem, or an
  item that must be decided rather than measured). It stays open until a run
  closes it with a reason. `source` says *who keeps the record*; `route` says
  *whose call it is* — they are independent.
- An item that genuinely needs Tim is filed, routed `tim`, **and** surfaced here,
  because nothing else reaches a human: this profile's cron jobs deliver `local`
  (their WebUI origin has no gateway adapter — see `cron-delivery-target-broken`),
  so reports land in `cron/output/<job-id>/` and in this repo, nowhere else.
  `bin/tc_ops.py escalations` prints exactly those items and nothing else.