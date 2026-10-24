# Authoring a PRD — turbo-carnival house shape

How a PRD is written and landed in this repo. Read one of the existing files in
`docs/prd/` first — they ARE the shape — and treat this file as only the mechanics that
repeat across every one of them.

## Where the work is organised

- **One file per iteration: `docs/prd/NNNN-slug.md`.** The number is the highest existing
  + 1; the filename's `NNNN` IS the identity, so never add an `id:` field.
- **Frontmatter: `venture:` + `source:`** (the plan or document the work came from) — and
  nothing else. The `intent:` field and the `bin/publish_prd` emitter belong to the
  publish-driven repos (t-chat / t-genetics); this repo dropped `publish_prd`, and tickets
  here are cut by an agent against `docs/PROJECT_PLAN.md`.
- **Status block under the H1:** `> **Status:** CURRENT · <what was measured, dated> ·
  <what it waits on>`, then a `Plan item:` / `Track:` line. Status vocabulary is
  CURRENT / REFERENCE / HISTORICAL / UNREVIEWED / SUPERSEDED — defined in `docs/README.md`.
- Track is one of the plan's workstreams (`core-infrastructure` / `experiment` /
  `day-to-day`) and mirrors the board's `Track` field exactly — one field, so a ticket
  cannot sit in two places.

## House section order

Summary → Problem / motivation → Goals / Non-goals → Scope — In / Out → *(Boundary table,
when another PRD or issue touches the same ground)* → Acceptance criteria → User stories /
job-to-be-done → Edge cases & red lines → Metrics / definition of done → Open questions.

- **Problem / motivation is a NUMBERED findings list (`F1…Fn`), each carrying the file or
  the run behind it.** Paste the command and its output — an `ls` that says absent, a
  `grep` that returns nothing, a `bundle exec` count. A finding with no reproduction is
  archaeology, and the repo's own standard is that none of them are guesses.
- **State the boundary when the scope is adjacent to another doc.** A short table —
  concern · owner · **not this PRD** — keeps a future agent from averaging two documents
  that both describe conventions. Inventory the existing PRDs and the board's epics/open
  issues BEFORE writing: part of what you are about to specify is usually already owned,
  and re-cutting it gives one rule two homes.
- **Acceptance criteria are Gherkin scenarios inline in the PRD** (```` ```gherkin ````
  blocks) while the repo has no BDD lane. Do NOT create `gherkin_specs/` to hold them —
  a lane the repo will not run is worse than no lane. If a BDD lane is ever adopted, the
  scenarios migrate to `.feature` files and must not be maintained twice.
- **Every gate named must state the direction in which it FAILS.** "CI is green"
  specifies nothing, because a lane can be green while executing zero examples. Write the
  failing case beside the passing one, and prefer anti-vacuity scenarios (a run that
  executes 0 examples must fail the build; a gate demonstrated only in its passing
  direction has not been tested).
- **Metrics / definition of done: every line maps to an enforced gate** — a CI job, a
  `bin/verify` member, a cron, a spec. **A line that names a NUMBER must additionally map
  to an EMITTED metric**, not merely a pass/fail gate: a numeric goal with no telemetry is
  untracked and nobody is alerted when it stalls. If the repo's machinery cannot produce
  the number, say so and name it as a measurement gap — do not quietly drop the line.
- **Open questions name WHO rules and carry a lean recommendation.** Read the authority
  ladder in `AGENTS.md`: a credential, a platform setting, an intensity/identity call, or
  a GPU policy is the founder's; a measurement, a style or a format call is the system's.
  Never phrase a founder decision as a build ticket.

## Wire the PRD into truth in the same change

An unlisted document is not truth here. Adding a PRD means editing these surfaces in the
same commit:

1. **`docs/README.md`** — the `prd/` line in the Current inventory gains the new `NNNN`
   and one clause saying what it is.
2. **`docs/PROJECT_PLAN.md`** — a row in the matching workstream table
   (`| **W<x>.<y>** | <item> | \`docs/prd/<NNNN>-…\` | **spec written** <date> · <state> |`),
   a bullet in that workstream's rationale list, and an entry in §6 *Ordering — what
   blocks what* when the item blocks, or is blocked by, anything. The plan id is the join
   key between plan and board and is NEVER renumbered once a ticket cites it.
3. **Archive or status-stamp anything it supersedes.** One truth per topic — never write
   a `v(N+1)` alongside the old document; fix the CURRENT one instead.

## Board tickets: one parent epic per PRD, child tickets under it

House pattern (founder, 2026-10-19): a PRD's tickets are not cut loose — they live
under a **parent epic** on the board.

- **Epic first: `[PRD NNNN] <title>`.** Body links the plan anchor, the PRD path, and
  the board URL, and lists the child tickets. Cutting the children first is fine, but
  the epic must exist before the children get wired.
- **Every child references the parent in its body** — a `Parent: #<epic>` entry in the
  Linkage block (or a `Parent : #<epic>` line in the header block, for tickets that
  carry one). That body line is a CONVENIENCE and creates nothing — the linkage is the
  **native GitHub sub-issue parent edge** (see next section).
- Epic titles carry the `[PRD NNNN]` prefix (see #20, #36); children carry the
  `ticket` + `prd:NNNN` labels — create the label first if absent (`gh issue create`
  exits 1 on an unknown label). The epic's Track mirrors the PRD's track; children sit
  at `Todo` until claimed. Board mechanics: `references/github-board-api.md`.
- Worked example: PRD 0007 → epic #113 with children #103–#112, all `Todo` /
  `core-infrastructure`, parent wired into every child body.

## The PRD parent edge — `bin/prd_link`

The `[PRD NNNN]` ticket is the parent and stays TOP-LEVEL; every child is linked to it as a
native GitHub **sub-issue**. The edge IS the linkage; `prd:NNNN` is a filterable tag, never
the link. Before this command existed the edge was hand-made, so it held only as long as
somebody remembered, and a lost edge could not be repaired by re-running anything.

```bash
bin/prd_link --check          # drift gate: non-zero when a prd:NNNN child is unparented,
                              # or when a PRD ticket itself carries a parent
bin/prd_link --apply          # repairs missing edges in place
bin/prd_link --prd 0007       # scope either mode to one PRD
```

- **CI runs `--check` on every PR** (`prd_link` job, scoped read permissions). A lost edge
  fails the build instead of waiting for an audit.
- **Never creates, reopens, or closes an issue, and never moves a board Status.**
- **Never parents a PRD ticket to itself** — the PRD ticket usually carries its own
  `prd:NNNN` label, so it is dropped from its own expected-children set, and a PRD ticket
  that already has a parent is a REPORTED violation, not something silently unlinked.
- Repo resolves from the checkout's own `origin` remote; no remote, or no `docs/prd`,
  exits 2 rather than printing a vacuous `ok` over an empty set. A green check over an empty
  set is the failure mode to keep out: it looks like health.
- Creating the edge is not idempotent (re-adding a child is a 422): read the parent's
  children ONCE as a skip list, and POST with `-F sub_issue_id=<database id>` — never
  `-f`, which stringifies the id.
- **A pull request counts among sub-issues.** `extra=` in the report legitimately mixes
  closed children and linked PRs; report it, never remove it.
- **Distribution: byte-identical, never forked.** This command ships into generated
  ventures verbatim, citing the merge sha. When a downstream ticket needs behaviour it
  lacks, change it HERE and re-ship — a template-local variant is exactly the drift the
  mechanism exists to prevent (same rule as `bin/rspec`'s agent signal).

Regression coverage: `.github/scripts/test-prd-link.sh` with `.github/scripts/stub-gh` —
stubbed `gh`, no token, no network — proves the edges set, that a dropped edge goes red and
is repaired, and that the PRD ticket stays top-level. Verify the suite BITES by running it
with the sabotage knob on; a suite that passes with linking disabled is testing nothing.

## Landing it (the PR)

- Branch off `origin/main`; stage only the PRD + index + plan paths with `git add <paths>`,
  never `git add -A`.
- **A spec-only PR uses `Refs #<n>`, never `Closes #<n>`.** Nothing implements the issue,
  and `Closes` would shut a parent whose work has not started (it also rots an unanswered
  ruling ask on a closed thread nobody re-reads). When no epic exists yet because tickets
  are held, say exactly that in the body — *"spec PR — tickets not cut, held pending
  founder rulings Q1–Q5"*.
- **State the gate disposition honestly.** A markdown-only diff has nothing for rspec or
  packwerk to read; if `bin/verify` or a single lint entry point does not exist yet, say
  so rather than ticking a box for a gate that never ran.
- **Commit message:** `W<x>.<y> PRD NNNN: <what it establishes>`.
- The founder delegates the merge ("You merge") — squash-merge your own PR once CI is
  green, rather than leaving it for a founder sweep.
- **Closeout names scope gaps no ticket owns.** Before marking Done, check the parent PRD's
  acceptance items against what the ticket's success criteria actually covered; any remainder
  — a PRD sub-item neither this ticket nor a sibling owns — gets named in the evidence
  comment as an open item so it does not silently vanish.

## Verify before you claim

Work the repo's own rule: report only what a read-back proves. Before the PR, confirm the
PRD path, the index line and the plan row all exist on the branch (`git status --short`
should list exactly the paths you staged), and read the created PR body back — a body
that silently lost its sections is a claim you cannot make.
