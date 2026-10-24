# GLCommand commands, and the attribution spine (`packs/attribution`)

Traps verified in this repo on 2026-10-19 while landing #38 (prompt parts + the spine writer). Load this
before adding or debugging a `GLCommand` command, before touching `packs/attribution`, or before trusting a
red `bin/rspec` run.

## GLCommand: an undeclared argument is SILENTLY DROPPED

`GLCommand::Callable.call` merges `DEFAULT_OPTS = { skip_unknown_parameters: true, ... }`, so an argument the
command did not declare in `requires`/`allows` is **discarded without an error** — the command just runs
without that input. A typo'd or renamed key fails as *silence*, not as a crash. Measured: passing
`width:`/`height:` to a command that had only declared `asset_width:`/`asset_height:` ran "clean" and wrote
nils; the only symptom was `error=unknown keywords: :width, :height`, visible only once the arguments were
printed.

Consequences:

- **Declare every axis you intend to accept.** The `allows` list IS the command's interface; a key missing
  from it cannot be passed at all.
- **When the ABSENCE of an argument is load-bearing, assert it in a spec.** The mechanical way to say "there
  is no way to pass an assembled prompt" is
  `expect(described_class.arguments).not_to include(:prompt)`. A red line enforced only by a comment is a
  preference.
- **`.call` returns the CONTEXT, not your return value.** On failure the `returns` accessor is never
  assigned, so `result.foo` is `nil` and a refusal surfaces as `NoMethodError: undefined method 'bar' for
  nil` far from the real cause. In specs, assert `expect(result).to be_success` FIRST, then read `result.foo`.
- **Assert a refusal by its message**: `expect(result.full_error_message).to match(/…/)`. For
  `stop_and_fail!("...")` it equals that string verbatim (use `eq` when exactness matters).
- `raise_for_invalid_args!` runs BEFORE `call`, so a validation inside your body is what surfaces through
  `context.error`; an undeclared key never reaches the body to be checked at all.

### A `return X if cond` bug that cost a run here

`return X if cond` returns **nil** when `cond` is true and `X` is nil — it does NOT fall through to the next
line. This silently returned nil instead of building a new row whenever a candidate was supplied:

```ruby
return Attribution::Render.find_by(image_candidate_id: c.id) if c   # nil when no row exists yet
Attribution::Render.new                                             # never reached
```

Write `Attribution::Render.find_by(...) || Attribution::Render.new`, and make specs cover the
present-but-absent-row case and the no-candidate case separately (an `image_candidate` present with no render
is exactly the first-write path).

## Never point a `rails runner` script at the test database

`RAILS_ENV=test bundle exec rails runner ...` COMMITS its rows. The test DB is shared by every spec, so one
leftover `pipeline_runs` / `pipelines` / `image_candidates` row flips specs that assert counts or let
`SelectNextJob` choose a mode. Measured 2026-10-19: **14 unrelated specs went red**, including
`CreatePipelineRun#call rolls back on failure` reading `PipelineRun.count == 1` and every
`SelectNextJob` mode assertion.

- Debug against the DEV database, or from inside an rspec example.
- Recovery: `bin/rails db:test:prepare`, then re-run `bin/rspec`.
- **Compare the failing-EXAMPLE LIST, not the failure count**, before calling anything "pre-existing". A
  count is compatible with a completely different cause; an identical list is evidence.

## Measuring a baseline before blaming your change

A failure count is not evidence; the *list* of failing examples is. Two traps sit between you and a real
baseline:

- **`git stash` cannot remove COMMITTED work.** Once the change is committed the tree is clean, `git stash
  push` stashes nothing, and the "baseline" run silently executes *your* code — it then reports your own
  example count, which is easy to mistake for the baseline. (`No stash entries found` on the pop is the
  tell.)
- **A `git worktree` cannot measure a Rails suite baseline.** The worktree holds tracked files only, so
  gitignored environment files (`config/master.key`, `.env`, `storage/`, `tmp/`) are missing and the request
  specs fail in bulk — a failure of the harness, not of the commit.

Measure in the main checkout, detached at the parent, then come back:

```bash
git checkout -q <parent-sha>          # safe: your work is committed and pushed
bin/rspec 2>&1 | grep -E "examples,|^rspec ./"
git checkout -q <your-branch>         # then confirm HEAD + a clean tree
git diff --stat HEAD -- <your paths>  # empty = no drift left behind
```

Diff the two failing-example lists. Identical lists with a different example count is the normal shape of
"my change added examples and broke none"; a matching *count* with a different *list* is a different bug
entirely.

## Reading data before booting Rails into the test env

For a read-only question ("are these tables empty?"), do not start Rails at all — go to psql. It cannot
pollute anything and it is faster:

```bash
DB=$(awk '/^development:/{f=1} f && /database:/{print $2; exit}' config/database.yml)
psql -d "$DB" -tAc "select 'renders='||count(*) from renders
  union all select 'posted='||count(*) from scheduling_posts where status='posted';"
```

Always name the environment you mean (`development` vs `test`) when reporting the numbers: a dev-DB count
and a test-DB count are different facts, and a test DB that is *not* empty is itself a finding.

## `PipelineRun` broadcasts on EVERY update — a bare factory cannot be updated in a spec

`PipelineRun` includes `Turbo::Broadcastable` with `after_update_commit :broadcast_run_update`, which renders
the **full** `runs/run_card` partial. A factory run with no persona or steps makes that render raise
`ActionView::Template::Error: undefined method '[]' for nil` (`_run_card_content.html.erb`), so **any
`run.update!` inside a spec** becomes a template error that reads like a model failure.

Pass the values at CREATION time (`create(:pipeline_run, variables: { ... })`) instead of updating, unless the
example is specifically about the broadcast.

## The attribution spine — the contract on top of #37's tables

#37 landed the schema (`assets`, `renders`, `render_prompt_parts`, `render_loras`, `assessments`) and the
models; #38 landed the writing contract. Each rule below is enforced by specs, several of them asserted in the
negative.

- **One writer: `Attribution::RecordRender`.** Render + named prompt parts + LoRA set in one transaction; the
  asset is linked on `sha256` through `Attribution::Asset.record`; idempotent on the unique
  `renders.image_candidate_id`. A *pipeline run* is deliberately NOT a key — one run legitimately produces
  several renders.
- **Prompt parts are named, and the vocabulary is closed.** `Attribution::PromptPart::NAMES` =
  `identity`, `scene`, `wardrobe`. `negative` is RESERVED because it is the single-valued
  `renders.negative_prompt` column (one fact, one home). To add an axis, edit `NAMES`; never introduce a new
  bare string at a call site.
- **Recorded attribution is immutable.** Re-recording the same facts is a no-op; recording *different* parts on
  an existing render is refused, because editing in place destroys the comparison retroactively — the same
  failure mode as the DB-only workflow column.
- **A part is never extracted after the fact.** `Attribution::PromptParts` (ordered `name -> text`) is the only
  accepted source and has deliberately **no** `from_string`/`parse`; the writer refuses a bare String. If you
  feel the need to parse an assembled prompt into parts, stop — that is the red line.
- **"One axis" is a query, not a convention.** `Attribution::Render#varying_parts(other)`,
  `#differs_in_exactly_one_part?(other)`, and `Attribution::Render.varying_one_part_from(render)` — the last is
  a SQL relation with three `HAVING` checks: same part count, no part name the anchor lacks, exactly one
  differing text. Absent counts as DIFFERING (silence must not read as agreement).
- **`renders` is EMPTY in production — identify which cause before touching anything.** There are two, and
  they are independent: (1) nothing calls the writer yet, because the parts generator is the local-brain
  Thinker (W1.1); (2) the *sync* path builds no candidate chain at all —
  `ContentPillars::Photo.import_render` writes `image_candidate: nil`, so only the async `ProcessJobResult`
  path creates candidates, and `Growth::RenderReach`'s join finds nothing for most posted posts. Both are
  owned by an open core-infrastructure ticket. Do not "fix" either by inventing parts or backfilling a guess
  (a guessed checkpoint or part silently poisons every later query), and do not read the empty result as a
  bug in the query or the writer.

## The content config version — the address a metric shift has (`packs/attribution`)

`Attribution::ContentConfigVersion` (`content_config_versions`) makes the config a first-class object, so
"the config changed and reach moved" has something to attach to. Before it, the config lived across
`content_pillars` rows, the scene bank in `Growth::PillarPrompt`, and `pipeline_steps.comfy_workflow_json`.

- **What it pins**: pillar, wardrobe rung, checkpoint, the LoRA set (strength + on/off), negative, workflow
sha, prompt parts — as columns and rows, never a blob. **What it deliberately does NOT**: seed, asset,
timestamp. Those vary per RENDER, and one version legitimately covers hundreds of renders — that is what
makes two render sets comparable at all.
- **Identity is DERIVED, never authored.** `ContentConfigVersion.digest_for(pins)` (sha256 over a canonically
sorted serialisation) is assigned in `before_validation`; `#pins` / `#recomputed_digest` / `#consistent?`
re-derive it from the row's own columns and children. Canonical order means part ORDER is not identity, but a
changed LoRA `enabled` flag IS (an off slot at 0.75 is a different config from an absent slot).
`workflow_path` is provenance and is excluded — the sha is what the graph IS.
- **Writing one: `Attribution::RecordContentConfigVersion`**, the single writer. Idempotent BY CONTENT, not
by argument: the same pins resolve to the same row, a changed pin writes a NEW row. It refuses a String in
place of named parts and an empty part set, exactly as `RecordRender` does.
- **Immutability in three layers** (trigger mechanics in SKILL.md): derived digest, `#readonly?` on a
persisted row, and a `BEFORE UPDATE OR DELETE` trigger on the version AND its child rows — a mutable child is
an edit wearing a costume, since the digest names the children.
- **Every render created now references one.** `renders.content_config_version_id` is nullable (pre-spine
renders read as UNKNOWN, never a default version), and `RecordRender` refuses a render created now with no
version while leaving a fill-in on an EXISTING row exempt. That refusal is a WRITER-CONTRACT change: any
other ticket wiring a render path must construct or select a version first.
- **Comparing versions: `Growth::VersionOutcomes`** (growth_harness) groups by version over
`Growth::RenderReach`'s ONE chain rather than re-writing those joins — a second copy of the chain is how two
answers about the same assets drift apart. Unmeasured reach stays NULL, never 0.

## Sabotage-probing is the acceptance test for a new guard

Break each guard in the real code and confirm the suite goes red, then restore. Measured 2026-10-19, four
probes against `Attribution::RecordRender` and `Attribution::Render`:

| sabotage | caught? |
|---|---|
| an absent prompt part reads as agreement (`(mine.keys \| theirs.keys)` weakened to `theirs.keys`) | **NO at first** |
| the same-part-count `HAVING` removed from the query | **NO at first** |
| recorded parts overwritten instead of refused | yes |
| a bare String accepted as the prompt parts | yes |

The two that escaped are invisible in the *symmetric* case (both renders carrying the same part names), which
was the only case the specs exercised. The fix: assert **both directions**
(`arm.varying_parts(control)` AND `control.varying_parts(arm)`) and add the asymmetric exclusions to
`.varying_one_part_from` (a render differing in one part **and** missing another; a render carrying a part the
anchor lacks).

Rule: **a guard with no failing probe is unverified.**

**A guard can also be absent for a reason that is not your diff.** With schema format `:ruby`, a database
trigger exists only if `db/triggers/*.sql` is applied to the test database before the suite runs, so "the
guard is installed" is itself a claim to probe: drop the guard from the test DB and remove the loader, and
the guard's examples must go red (measured: 5 of them). A green suite against a guard that was never
installed is exactly the failure that probe exists to catch.
