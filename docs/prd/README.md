# PRDs — product requirement documents

One PRD per product iteration: `000N-slug.md`, plus its Gherkin feature spec
in `gherkin_specs/<domain>/<slug>.feature`. The PRD is the input to the
autonomous pipeline (see AGENTS.md §loop & pipeline): publish the PRD →
tickets on the board → the dev worker implements them.

Every definition-of-done line in a PRD must map to an enforced gate; if a
line can't be enforced, delete it at review.

## This repo (turbo-carnival)

The repo's product requirements live here as numbered PRDs. Status follows the
`docs/README.md` convention (`CURRENT` is authoritative; `HISTORICAL` /
`SUPERSEDED` are records). Work is cut from PRDs as GitHub tickets on board
pi-216 project 5 (`https://github.com/orgs/pi-216/projects/5`), each carrying a
`prd:NNNN` label.

**The parent edge is the linkage; `prd:NNNN` is a tag.** A ticket belongs to a
PRD because it is a **sub-issue** of that PRD's own `[PRD] PRD NNNN — …` ticket,
not because it wears a label. The label stays — the PM and the worker filter on
it — but it is a tag, never the link.

That edge is owned by one command, and a re-run is the repair:

```bash
bin/prd_link --check     # the drift gate: exit 1 if any child is unparented
                         # or a PRD ticket itself has a parent
bin/prd_link --apply     # repairs missing edges in place (created=0, always)
```

It never creates or reopens an issue, never moves a board Status, and never
gives a PRD's own ticket a parent. CI runs `--check`, so a tranche that loses an
edge fails the build instead of waiting for an audit (#121).

| PRD | slug | status | scope |
|---|---|---|---|
| 0001 | local-uncensored-brain-and-phase-machine | CURRENT | the uncensored local brain + phase machine |
| 0002 | versioned-content-config-and-experiment-db-spine | CURRENT | versioned content config + experiment DB spine |
| 0003 | repo-conventions-and-a-verifiable-done | CURRENT | repo conventions, `bin/verify`, CI truth |
| 0004 | the-experiment-lane | CURRENT | the experiment lane and its roles |
| 0005 | miniskirt-pillar | CURRENT | the miniskirt content pillar |
| 0006 | harness-conformance-to-rails-venture-template | CURRENT | parity conformance to `rails-venture-template` (W1.4) |
| 0007 | safety-posture-reduction | CURRENT | the legal floor + A/B/C triage of the agent-authored controls (W1.5) |

## The two-layer Gherkin rule (PRD 0006 Q2, founder ruling 2026-10-19)

Gherkin is the house **notation** for describing behaviour, and it has two
layers — never collapse them.

- **Layer 1 — Gherkin as notation (definitions).** House-wide. Every PRD
  describes behaviour in Gherkin *notation*, whatever implements it: the Rails
  app, the Python/ComfyUI render pipeline, the shell harness, the cron jobs. A
  definition is **not** a test.
- **Layer 2 — Gherkin as executable tests (Ruby/Cucumber).** Required for **the
  Rails application only** — its HTTP surface, its UI, its commands. Behaviour
  implemented by any other tool is defined in Gherkin and is **not** required
  to have an executable Ruby Gherkin test; it is tested by that tooling's own
  suite.

Where the executable scenarios live: `gherkin_specs/` (see `gherkin_specs/README.md`).
Non-Rails behaviour stays inline in the PRD permanently (Q9) — it is never
extracted into `.feature` files and never executed in Ruby. A future agent
reading a render-pipeline scenario in a PRD must **not** try to execute it in
Ruby; only Rails-app scenarios become `.feature` files.
