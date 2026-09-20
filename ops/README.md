# ops/ — the fix loop

Monitoring in this repo detects problems (harness logs, GPU-scheduler state, cgroup
telemetry, cron output, Rails data). This directory is where a detection becomes a
**tracked, closable work item**, so the same failure is not re-diagnosed from
scratch every few days.

| path | what it is |
|---|---|
| `board/<key>.json` | one issue per STABLE key; repeated probes refresh the same file, never duplicate it |
| `board/archive/<key>.jsonl` | note history trimmed out of the live record (archived, never deleted) |
| `NEEDS_HUMAN.md` | **generated** — markdown digest of every open item, written by `bin/tc_ops.py probe` |
| `systemd/`, `backups/` | unit files and repo backups for this loop |

## Start here

```bash
python3 bin/tc_ops.py list          # open items, by severity
python3 bin/tc_ops.py show <key>    # full record: evidence, notes, provenance
cat ops/NEEDS_HUMAN.md              # the same board as a readable digest
```

`tc-ops-triage` (Hermes cron, hourly) runs `probe`, works the open items, and
commits the board. `bin/tc_ops.py selftest` asserts the pure decisions the board
depends on — run it after touching the checks.

## Conventions

- `source=probe` — the probe owns the key: it re-files while the condition
  reproduces and auto-closes it when it stops. Closing one by hand does not stick.
- `source=manual` — filed by an agent or by hand (an outside-scope problem, or a
  decision a human must make). It stays open until a run closes it with a reason.
- A finding that needs Tim is filed **and** recorded here, because nothing else
  reaches a human: the profile's cron jobs are `deliver=origin` on a platform the
  gateway cannot deliver to (`cron-delivery-target-broken`), so reports land on
  disk and in this repo, nowhere else.