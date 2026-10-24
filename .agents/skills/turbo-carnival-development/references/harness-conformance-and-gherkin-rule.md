# Harness conformance (PRD 0006 / W1.4) — the two-layer Gherkin rule and the parity audit

## The two-layer Gherkin rule (founder ruling Q2, 2026-10-19) — MEMORISE THIS

The founder's words: *"we like Gherkin notation for definitions, but the ruby gherkin tests are only
required to test the rails application itself."*

| layer | what | where | executable? |
|---|---|---|---|
| **Layer 1 — notation** | Every PRD describes behaviour in Gherkin notation, whatever implements it: the Rails app, the Python/ComfyUI render pipeline, the shell harness, the cron jobs | inline in `docs/prd/*.md` (narrative + ` ```gherkin ` blocks) | **No** |
| **Layer 2 — executable** | Cucumber + `gherkin_specs/` + step definitions + `.gherkin_lint.yml` | `gherkin_specs/**/*.feature` | Yes — **Rails application only** |

**The trap:** a render-pipeline or cron scenario in a PRD is a *definition*, not a failing test. Do not try
to execute non-Rails behaviour in Ruby, and do not read "no executable test" as "not defined". Conversely
do not create duplicate truth: one scenario has one home. When a Rails-app scenario becomes executable it
moves into a `.feature` file with lineage tags (`@PRD-0006`, per-scenario `@DEV-NNNN`) and the PRD keeps the
narrative, not a second copy.

**Where the definitions live (Q9, 2026-10-19):** non-Rails definitions stay **inline in the PRD,
permanently**. They are never moved into a `.feature` file, there is no `@non-executable` tree in
`gherkin_specs/`, and no future non-Ruby runner is implied. Only Rails-app scenarios get a `.feature` home.

This is why PRD 0003's "no Gherkin lane" non-goal was **superseded**: PRD 0006 / ticket **#83** adopts the
lane, scoped to the Rails app. If you find PRD 0003's line saying the BDD lane is out, that line is scoped
to PRD 0003's own deliverables — the repo-wide rule is the two-layer one above.

## The rails-venture-template parity audit (how W1.4 was done)

turbo-carnival is the one pi-216 venture **not** scaffolded from `rails-venture-template`. The template is a
**snapshot, not a sync** — never re-scaffold; port file-by-file and prove byte-identity.

Audit mechanically — existence + a run, never a guess:

```bash
# rails the template locks, as file existence
ls app/commands/application_command.rb config/initializers/sentry.rb bin/verify \
   bin/test-agent-signal lib/rspec/agent_formatter.rb FOUNDERS.md .github/pull_request_template.md \
   docs/prd/README.md docs/tech_design_docs packs/README.md \
   gherkin_specs config/cucumber.yml .gherkin_lint.yml .erb_lint.yml 2>&1
# gems the template pins
for g in strong_migrations erb_lint bundler-audit timecop n_plus_one_control database_cleaner \
         aasm oj haml-rails rswag-api cucumber gherkin_lint sentry-rails; do
  grep -q "^    $g " Gemfile.lock || echo "ABSENT: $g"; done
bundle exec packwerk check | tail -2
```

**Most template files are heredocs inside `template.rb`, not files in the template repo.** Only
`bin/rspec`, `bin/test-agent-signal`, `bin/lint`, `bin/smoke` and `lib/rspec/agent_formatter.rb` are real
files there. So "copy byte-identical" for `application_command.rb`, `sentry.rb`, `bin/verify`, the AGENTS
contract, `FOUNDERS.md`, `THESIS.md`, `.gherkin_lint.yml`, `config/cucumber.yml` means: extract the
`file "<path>", <<~'CODE' … CODE` heredoc body from `template.rb` at a **pinned merged commit**
(`git -C <clone> rev-parse origin/main`), dedent it, write it. Never hand-author a variant. `<<~` dedent semantics: strip the common leading whitespace of the non-empty lines, and keep the body's trailing newline by dropping the empty last `split('\n')` element before rejoining (`dedent_block(lines[0..-2]) + "\n"`) — compare SHA256, never eyeballed diffs.

## The parity audit as a standing gate (`scripts/parity_audit.rb`)

The W1.4 audit is now a permanent `bin/verify` gate, placed between the `lint` gate and `bin/rspec` (fail-fast: it boots in ~2s, before the long test lane). Contract:

- **One line per rail R1–R9, in order** — `CONFORM` / `GAP` / `DEVIATION(reason)`, the reason citing the ratified deviation and its ruling/ticket — then a `PARITY OK — n CONFORM, m DEVIATION, k GAP` / `PARITY FAILED — GAP on R…` summary line.
- **Fail-closed exit codes:** 0 = no rail in GAP; 1 = one or more GAP; **2 = no disposition** — a rail that produced no verdict at all is an error, never a silent missing. Every probe is wrapped so an exception becomes `GAP: probe error (fail-closed)` instead of a skip; a debug hook (`PARITY_AUDIT_SKIP=R9,R3`) suppresses listed rails and doubles as the built-in proof of the exit-2 path.
- **Verdicts go to stdout** (`puts`, not `warn`) — a stderr error line is invisible to the stdout-asserting spec and the CI grep.
- **Byte-identity is SHA256-pinned in the script** against two template trees: the **generator pin** (template HEAD — the artifacts live in `template.rb` heredocs) and the **files pin** (the merge commit where the test-signal trio is a real tree file). Pick the pin by where the artifact actually lives.
- **Prove every probe can fire (the sabotage matrix).** The audit's spec rewrites one probe target per rail — delete the layout's head meta (R2 GAP), rename the probe constant's file (R4 GAP), append a line to a ported artifact (R6 GAP), skip a rail via the env hook (exit 2) — asserting the rail flips to GAP + non-zero, then restoring and asserting zero again. **A CONFORM you have never seen fire from is unproven.** In the first version the artifact check compared a rail's ID symbol to its Rail object, so every byte-identity check silently no-op'd and the rail still read CONFORM — only the drift sabotage caught it.
- **Specs that mutate the working tree: single-file rename, idempotent ensure, `git status` after.** `FileUtils.mv(dir, stash)` + `mkdir_p(stash)` on the re-run moves the dir INSIDE the existing stash — a few runs deep the tree reads `models/models/models/…`, every later probe reads corrupted state, and a crashed ensure (`rmdir` on the already-moved dir) hides it. When a subprocess probe's result unexpectedly changes, check `git status --short` for tree corruption BEFORE env-bisecting — the env looks different (RUBYOPT / BUNDLE_GEMFILE inherited from the rspec process) and usually is not the cause.
- **Gate wiring:** the parity gate sits after `lint`, before `rspec`; the template's BDD-lane members (`cucumber`, `gherkin_lint`) are added **conditionally — members while any `.feature` file exists** (the template's own condition, not a turbo-carnival invention); build the success line dynamically from the gates that ran so it never claims a gate that was skipped.

## The single lint entry point (`bin/lint`, PRD 0006 R8 / ticket #91)

`bin/lint` is the only way the style linters run — `bin/verify` and CI call it, never raw `bin/rubocop` /
`erb_lint`. The guard spec (`spec/repo_conventions_spec.rb`) asserts CI and `bin/verify` contain
`bin/lint` and NOT `bin/rubocop` — keep the literal string out of those two files, **comments included**
(its own comment tripped the guard once).

- **Call the `bin/rubocop` binstub, not `bundle exec rubocop`.** The binstub pins the repo-local
  `.rubocop.yml` and carries the cgroup OOM guard — bypassing it silently drops both.
- `-f FORMAT` passthrough for CI (`bin/lint -f github` for PR annotations); `--branch` lints only the
  files changed vs `origin/main` and parse-checks every changed `.rb` first.
- Parity: R6's expected verify members consolidate rubocop + erb_lint into the `lint` member; R8 reads
  CONFORM once `bin/lint` exists (ratified state 6 CONFORM / 3 DEVIATION / 0 GAP as of 2026-10-21).
- AGENTS.md's content contract (single lint entry point, generated files, comment policy, no
  exfiltration) has its own guard spec; read back the greps against the MERGED copy before claiming the
  doc write.

## The four doc homes (PRD 0006 F4) — author them, don't copy them

The four root documentation homes are `ARCHITECTURE.md`, `CONTRACTS.md`, `OPS.md`, `DESIGN.md` — one
topic each, so a topic resolves to exactly one CURRENT document:

| home | owns |
|---|---|
| `ARCHITECTURE.md` | system shape: stack, pack boundaries, the command rail, the render pipeline (shape), the brain seat, the growth harness + two-venue design, the data spine (shape) |
| `CONTRACTS.md` | behavioural/data contracts + their enforcement points: the legal floor, each gate's contract (measure/verdict/failure mode), the command + state-machine + claim + test-signal + two-layer-Gherkin contracts, the attribution spine, the serving-layer contract |
| `OPS.md` | operations: the `bin/verify` gate, the honest `bin/*.sh` + `bin/*.py` command inventory, the cron fleet, the GPU claim lifecycle, the ComfyUI + brain runbooks, the render-pipeline mechanics, environment, deploy |
| `DESIGN.md` | the APP UI design system: Tailwind tokens, the ViewComponent library, navigation, the lookbook, the preview/testing convention |

- **Author with repo-specific content — do NOT byte-copy a template or a sibling.** This is the reverse of
  the parity audit above: the template does NOT emit these four (it ships `THESIS.md` / `FOUNDERS.md` /
  `docs/prd` / `AGENTS.md`, not the homes), so there is no heredoc to port. A sibling venture (`t-genetics`)
  has all four and is the canonical SHAPE reference — copy the structure and the provenance/one-truth
  headers, then fill every body from THIS repo's actual code, packs, `config/` and cron. A byte-copy is
  either empty or describes the wrong app.
- **`DESIGN.md` owns the app UI, not the persona's look.** The persona's visual rendering style is the
  render-pipeline's territory (growth-harness skill), not `DESIGN.md`; keeping them apart is what stops the
  two "design" truths from competing.
- **One truth per topic = archive, don't delete, and fix inbound links.** `git mv` each superseded doc into
  `docs/archive/` (history and provenance survive — deleting loses the audit trail), then grep the repo for
  references to the moved file and repoint the live ones (usually `README.md`). A doc absorbed into a home is
  recorded as Historical in `docs/README.md`; the home is the new single source.
- **`docs/README.md` records the four homes** — a "four doc homes" section + a one-truth row for each, so the
  index answers "which document is true for X" (the teeth of the index; see `project-governance`).
- **The root ends with exactly the home set + the standing docs.** After the pass the repo root holds only the
  four homes plus `AGENTS.md`, `FOUNDERS.md`, `README.md`, `THESIS.md`; any other top-level `*.md` is an
  unarchived competing source.
- **`bin/verify` green before close (house rule).** A docs-only change still runs the full gate from
  the worktree — expected to pass trivially, but a worktree that can't boot (unbuilt Tailwind, no DB) can't
  prove the docs, so fix the worktree first (see the "fresh worktree is not a built app" pitfall above).

## Sentry is agent work here (ruling Q3)

The DSN is **not** `founder_needed` — a token exists and an agent provisions it into encrypted credentials
via a ticket (#77). The gems arrive transitively (`gl_exception_notifier` ← `gl_command`) so
`bundle list | grep sentry` *looks* installed while **zero** events are captured: check for
`config/initializers/sentry.rb` and `grep -rn Sentry config/ app/`, not for the gem.

## Job substrate: Sidekiq only (ruling Q5)

`solid_queue` / `solid_cache` / `solid_cable` are being retired; **do not add new work on `solid_*`**.
Ticket #85 owns the migration. `config.active_job.queue_adapter` should be `:sidekiq`.

## Pitfall: `gh api graphql` mangles `$var` when the query is double-quoted

A mutation passed as `-f query="mutation($p:ID!…)"` through a shell loses `$p`/`$i`/`$f`/`$o` to variable
expansion and dies with a parse error that looks like a GitHub problem, not a quoting one:

```
gh: Expected VAR_SIGN, actual: COLON (":") at [1, 10]
```

**Fix: single-quote the query** (shell leaves `$` alone) and pass the values as separate fields:

```bash
gh api graphql -f query='mutation($p:ID!,$i:ID!,$f:ID!,$o:String!){updateProjectV2ItemFieldValue(
  input:{projectId:$p,itemId:$i,fieldId:$f,value:{singleSelectOptionId:$o}}){projectV2Item{id}}}' \
  -f p=PVT_kwDOE00cLc4BnqRm -f i=<item-id> -f f=<field-id> -f o=<option-id>
```

Python `subprocess(..., shell=True)` reproduces this exactly — prefer a file or single-quoted string.

## Pack autoload wiring: `packs-rails`, not a hand-wired block (ruling Q8)

The template hand-wires `Dir[Rails.root.join("packs/*/app/*")]` into `config/application.rb` because it pins
`packwerk` but does **not** ship `packs-rails`. turbo-carnival **keeps the gem** (`packs-rails`, ratified) and
does not hand-wire — the template's block is not a preference, it is what you do without the gem.

**The railtie constant is `Packs::Rails::Railtie` — not `Packs::Railtie`.** Probing `defined?(Packs::Railtie)`
returns nil and looks like the wiring is missing when it is working. Verify the mechanism instead:

```bash
bundle exec rails runner '
puts Rails.autoloaders.main.dirs.count { |d| d.include?("/packs") }        # 32
puts Rails.application.config.paths["app/views"].to_a.count { |d| d.include?("/packs") }  # 12
puts Rails.autoloaders.main.eager_load; puts Growth::Goal.name        # eager load genuinely works
'
```

Note `config.eager_load_paths` holds **0** pack dirs under the gem while the template pushes them in — a
cosmetic difference, not a defect: pack dirs are Zeitwerk root dirs, so eager loading resolves them anyway
(proven by the probe above).

## Board filing, idempotently

**Parent the tickets to their PRD issue (sub-issues).** The founder's convention here: the `[PRD]` epic is
the **parent issue** and every ticket it cuts is a **sub-issue** of it. A ticket filed without the parent is
incomplete — it is invisible from the PRD. Set it at filing time, not later:

```bash
ID=$(gh api repos/<owner>/<repo>/issues/<ticket-number> --jq .id)      # the DB id, NOT the number
gh api -X POST repos/<owner>/<repo>/issues/<prd-number>/sub_issues -F sub_issue_id=$ID
gh api repos/<owner>/<repo>/issues/<prd-number>/sub_issues --paginate --jq '.[].number'   # read back
gh api repos/<owner>/<repo>/issues/<ticket-number>/parent --jq .number                    # and reverse
```

`sub_issue_id` is the issue's **database `id`**, not its `number` — passing the number links the wrong
issue or 404s silently-ish. Verify in **both** directions (the parent's sub-issue list *and* the child's
`/parent`), and sweep every ticket number rather than trusting the ones you just added: partial parenting
is exactly the state a hand-edit leaves behind.

**Two-pass filing, with read-back.** `gh project item-add` **succeeds** even when the following field mutation fails, so a half-filed tranche
leaves issues on the board with no Status/Track. File in two passes and **verify by read-back**:

1. `gh issue create --body-file <path>` per ticket (write bodies to files — an inline body with a guarded
   word in it is refused by the terminal blocklist, and looks like a harness error).
2. `gh project item-add 5 --owner pi-216 --url <issue-url> --format json` → item id.
3. Set Status + Track via the single-quoted GraphQL mutation above.
4. Read back the **field values** (a `node(id:){... on ProjectV2Item{fieldValues…}}` query), not the item
   list — and skip any title that already exists on re-run.

Board ids for turbo-carnival (project 5) live in `config/autonomous/pipeline.yml`: `project_id`,
`status_field_id` + `status_options`, `track_field_id` + `track_options`. Status values here are
**Todo / In Progress / Done** (`todo: f75ad846`) — not Backlog.

PRD 0006's epic is **#75**; its tickets **#76–#85** carry the `prd:0006` label. `approved` is never set by
an agent.

## Gate members (PRD 0006 F3 / ticket #78) — what actually trips each gate

`bundler-audit`, `erb_lint` and `strong_migrations` are installed and two of them are CI gates (via
`bin/lint` for `erb_lint`). Probing them correctly matters more than installing them; three of these
cost a wasted cycle:

- **`strong_migrations` is wired by `ActiveSupport.on_load(:active_record)` →
  `ActiveRecord::Migration.prepend(StrongMigrations::Migration)` (`lib/strong_migrations.rb`), NOT by its
  railtie.** The railtie only loads rake tasks, so "no prepend in the railtie" is a false negative. Probe
  `defined?(StrongMigrations)` and `StrongMigrations.target_version` instead. A nil `target_version` does
  **not** disable the checks — it only gates the advisory lock timeout, and that only applies in a
  developer env. The gem must also stay **auto-required**: with `require: false` it installs,
  `bundle list` shows it, and the checks never fire.
- **Pick a probe that is genuinely unsafe.** `change_column :photos, :path, :text` **passes** — Postgres
  treats varchar→text as binary-coercible, so `adapter.change_type_safe?` returns true and
  `check_change_column` correctly allows it. A non-concurrent `add_index` on an existing table is the
  reliable tripwire ("Adding an index non-concurrently blocks writes"). Prove **both** directions: the
  unsafe form must exit 1 **and leave the migration unapplied with `db/schema.rb` unchanged**, and the same
  intent with `algorithm: :concurrently` + `disable_ddl_transaction!` must exit 0.
- **A probe migration must be reversible or it strands the DB.** `change_column` inside a `change` method
  is irreversible (`ActiveRecord::IrreversibleMigration` on rollback). Give a probe explicit `up`/`down`
  before running it, and read back the column type and `git status db/schema.rb` afterwards.
- **`bundler-audit check` takes a DIRECTORY, not a lockfile flag.** Seed a copy of `Gemfile.lock` in a
  scratch dir (downgrade one gem to a known-vulnerable version, e.g. `rack 2.0.0`) and run
  `bundle exec bundler-audit check <dir>` — the real lock must stay clean in the same session.
- **`erb_lint --autocorrect` is not whitespace-only.** On this repo it cleared 260 offences across 49
  files, but 12 files took token-level edits (void-element `/>`→`>`, `%>` joins). Run the full rspec suite
  before trusting it.
- **A guard spec asserting `exist` is too weak.** An *emptied* `.erb_lint.yml` satisfies `exist` and lints
  nothing — assert the substance (`include("exclude:")`). Sabotage-probe every guard case, including
  "file emptied" as well as "file deleted"; the emptied case is the one that slips through.

## A shared live tree means your branch is not yours alone

Multiple agents commit in one checkout, so a branch you just created can acquire someone else's commit —
and they may push it. Measured 2026-10-19: a branch created for #78 picked up an unrelated
`config/autonomous/*.yml` commit that was then pushed as `origin/harness/prd-0006-gate-members-78`, so
building the PR on that branch would have delivered another writer's work.

Build the PR commit from `origin/main` without touching the working tree or their commit — plumbing, not
checkout:

```bash
IDX=$(mktemp /tmp/idx.XXXXXX); export GIT_INDEX_FILE="$IDX"
git read-tree origin/main                 # seed the index from the TRUE base, not HEAD
git add <only your paths>                 # never `git add -A`; their files are dirty too
TREE=$(git write-tree)
COMMIT=$(git commit-tree "$TREE" -p origin/main -F /path/to/msg.txt)
unset GIT_INDEX_FILE
# then name a FREE branch for it — check `git ls-remote --heads origin <name>` first
git branch <free-name> "$COMMIT"
```

Verify before pushing: `git diff-tree --no-commit-id --name-only -r "$COMMIT"` must list only your files
and must not contain `config/autonomous`. Never rename, reset or delete the branch holding their commit.

## Stubbing an app constant in step definitions (Cucumber has no RSpec mock lifecycle)

Cucumber steps run **outside** RSpec's per-example mock lifecycle — `allow(...).to receive(...)` and
`RSpec::Mocks` are unavailable in step definitions. To stand in for a service the scenario must not call
for real (e.g. the age-gate vision probe), swap the constant with a bare `const_set` and restore it in
an `After` hook keyed to the scenario's lineage tag:

```ruby
@real_probe = CaptionGeneration.const_get(:VisionProbe)
CaptionGeneration.const_set(:VisionProbe, FakeProbe)   # bare const_set — no Warning.suppress
# ...steps run...
After('@DEV-NNNN') { CaptionGeneration.const_set(:VisionProbe, @real_probe) }
```

- **Do NOT wrap `const_set` in `Warning.suppress`.** It is **private in Ruby 3.4.5** and raises
  `NoMethodError` the moment the FULL suite runs (a single-feature run can mask it). Use a bare
  `const_set` and accept the harmless "already initialized constant" warning — it matches repo style.
- **`gherkin_lint` caps each step at 80 characters.** A naturally-worded step can tip over (81 chars)
  and fail the lint with `TooLongStep`. Reword shorter (e.g. "a queued post at the X tier whose age
  read is ..." → "a queued X-tier post whose age read is ...") and update the `.feature` file to match
  the step pattern. Run `gherkin_lint` (CI gate) before reporting the lane green.

