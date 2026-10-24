# Pack mechanics, spec discovery, and what packwerk really checks

> Measured 2026-10-19 while landing W1.2 #37 (`packs/attribution`, the attribution spine).
> Everything here was verified by running it, not inferred.

## Pack specs DO run in `bin/rspec`

`packs-rails` is loaded through the `.rspec` line `--require packs/rails/rspec`, which resolves
to a **gem** file (`gems/packs-rails-*/lib/packs/rails/rspec.rb`). The absent local
`packs/rails/rspec.rb` is therefore NOT a defect — do not "fix" it.

That integration appends every pack's `spec/` to the RSpec run list and every pack's
`spec/factories` to FactoryBot's `definition_file_paths`. So pack specs and pack factories are
first-class: **measured 204 of 662 examples come from `packs/`.**

**Trap that cost a wrong turn:** a dry run prints a file path only for PENDING or FAILING
examples, so `bin/rspec --dry-run | grep packs/` returns 0 and reads as "pack specs never run".
That conclusion is wrong. Count properly instead:

```bash
bin/rspec --dry-run --format json | python3 -c "import sys,json,collections;\
d=json.load(sys.stdin);print(collections.Counter(e['file_path'].split('/')[0] for e in d['examples']))"
# Counter({'spec': 458, './packs': 204})  <- measured 2026-10-19
```

A new pack MUST have `packs/<name>/package.yml` or nothing registers — no autoload path, no
spec discovery, no factory loading. Minimum shape:

```yaml
enforce_dependencies: true
dependencies:
  - "."                 # root package: ApplicationRecord
  - "packs/pipeline"    # only for constants the pack's CODE uses (e.g. PipelineRun)
metadata:
  owner: <owner>
```

Do NOT add `enforce_privacy` — the installed packwerk rejects it as an unknown key (4 existing
packs already fail `bin/packwerk validate` because of it).

## packwerk checks SPEC files too — so cross-cutting specs go in the ROOT package

A pack-local spec that references another pack's constants is a real dependency violation.
Measured: one spec using `ContentPillars::Photo`, `Scheduling::Post` and `ImageCandidate`
produced **6 offenses** in `packs/attribution`.

So when a spec compares a pack against tables/classes it legitimately does not depend on, put it
in the ROOT `spec/` package — its `package.yml` has `enforce_dependencies: false`, so the
reference is free and the pack boundary stays clean. Precedent:
`spec/models/content_pillars_photo_provenance_spec.rb`.

Reference numbers (2026-10-19): `bin/packwerk check` = **47 offenses** (AGENTS.md says 46 — it
drifted) and `bin/packwerk validate` FAILS on pre-existing manifests. Neither is yours: report
the DELTA. A new pack that adds 0 offenses is the target.

## Modelling an unknown axis: nullable, never defaulted

The repo's rule is **unknown stays unknown**. An input nobody recorded must read as NULL, because
a defaulted `0` / `false` is a fabricated measurement that poisons every later query — the same
class of error as `AddReachAttributionToGrowthSnapshots`' NULL-vs-0 rule.

So: no `default:` on an axis that can be unknown, no `null: false` on it, and a spec that asserts
BOTH halves:

```ruby
expect(render.seed).to be_nil
expect(render.seed).not_to eq(0)
```

Defaulted columns are for STRUCTURAL labels (a LoRA `layer` defaulting to `"base"`), never for
measurements.

## Prove the spec bites — sabotage it

A green spec on new code proves little. Temporarily restore the behaviour the change removes, and
confirm the spec fails FOR THE INTENDED REASON (not for a setup error):

- make the reader fall back to the old source (`pipeline_run.variables.dig("checkpoint")`) → the
  "reads from columns" spec must fail;
- default a nullable axis to `0` → the "unknown reads as NULL" spec must fail.

A test that passes with AND without the change is not evidence. Two refinements learned here:

- **Make the old source a DECOY, not an empty value.** A spec whose blob is `{}` still passes
  when the code falls back to the blob — it proves nothing. Put DIFFERENT values in the blob and
  assert the columns win: `variables: { "checkpoint" => "WRONG.safetensors", "seed" => 999 }`.
  That version catches the fallback (measured: `got: "WRONG.safetensors"`).
- **A factory supplies defaults you forgot.** `create(:render, seed: nil)` still gets
  `width`/`height` from the factory, so a derived `resolution` is present and the "absent"
  assertion fails on your own fixture, not on the code. Nil every axis the assertion covers.

## CI's `test` lane is green while executing nothing

Verified live on PR #68's own run: `bin/rails db:test:prepare test` printed
`0 runs, 0 assertions, 0 failures, 0 errors, 0 skips` and the job PASSED. The lane is over an
empty `test/`; the real suite is RSpec (`bin/rspec`, **712 examples** measured 2026-10-19).
Read the executed count out of the job log, never the check mark:

```bash
gh run view <run-id> --repo pi-216/turbo-carnival --log --job <test-job-id> | grep -E "runs,"
```

## `db/schema.rb`'s header moves on your first migrate — it is not your change

The app is on **Rails 8.1.4** (`gem "rails", "~> 8.1.0"`), so the schema DUMPER writes
`ActiveRecord::Schema[8.1]`, while every existing migration declares
`ActiveRecord::Migration[8.0]`. Running one migration rewrites that single header line. Keep the
migration at `[8.0]` (house convention) and say in the PR that the header line is a toolchain
artifact — do not revert it, and do not report it as a schema change.

## Worked example: the attribution spine (W1.2 #37)

`packs/attribution` is the pattern for a new pack:

```
packs/attribution/
  package.yml                                   # enforce_dependencies + deps
  app/models/attribution/asset.rb               # self.table_name = "assets"
  app/models/attribution/render.rb
  app/models/attribution/prompt_part.rb
  app/models/attribution/lora.rb
  app/models/attribution/assessment.rb
  spec/factories/attribution.rb                 # factory :attribution_render, class: "Attribution::Render"
  spec/models/*_spec.rb
```

- The namespace (`Attribution::Asset`) does NOT match the table name (`assets`), so every model
  sets `self.table_name` explicitly. That is the repo's existing idiom (`ContentPillars::Photo` →
  `photos`, `Scheduling::Post` → `scheduling_posts`).
- A migration that creates several related tables is ONE migration with a long WHY comment — see
  `20260820120000_create_growth_tables.rb` and `20261019120000_create_attribution_spine.rb`.
- Keep the migration ADDITIVE (create only). `git diff db/schema.rb | grep '^-'` should show the
  version header and nothing else — that is the check for "nothing existing was renamed or dropped".
