Closes #

<!-- Describe what this PR does and why it's necessary -->
<!-- Attach screenshots — for UI changes, show BEFORE (main/current) and AFTER (this branch) -->

## Author checklist

- [ ] Link the issue: `Closes #N` at the very top
- [ ] Attach relevant screenshots (both sides for UI changes)
- [ ] Changes covered by automated tests
- [ ] New controller actions carry authorization
- [ ] Frontend validations mirrored on the backend (and vice versa)
- [ ] Frontend changes tested for accessibility (ARIA, keyboard navigability)
- [ ] Migrations are schema-only (backfills in separate Rake tasks/workers)
- [ ] No hand-edited generated files (schema, lockfiles, snapshots)
- [ ] `bin/verify` clean (Tier-0 gate)

## Reviewer checklist

- [ ] Read the changes; ensure they do what the linked issue says
- [ ] Behavior changes covered by automated tests
- [ ] Auth verified on new controllers/actions
- [ ] Validation parity between frontend/backend
- [ ] Generated files regenerated, not hand-tuned
- [ ] Packs/bounded contexts respected (packwerk check green)

## Helpful links

- [AGENTS.md](AGENTS.md) — the content contract
