# Tasks — add-synthetic-provenance

## 1. Track provenance at creation
- [x] 1.1 Migration (phase 1, additive): add `synthetic` (boolean) and `provenance` (jsonb) to `photos`
      — `db/migrate/20260921040000_add_provenance_to_photos.rb`. `synthetic` is NULLABLE with no default
      on purpose: unknown is not human origin.
- [x] 1.2 Rake backfill task: mark the existing corpus synthetic with `provenance.embedded=false` — never silently default to human-origin
      — `lib/tasks/photos.rake` (`photos:backfill_provenance`, dry-run default). Applied 2026-09-21:
      `marked=337 remaining_unmarked=0`.
- [x] 1.3 Set the marker on the render-completion path from the existing attribution spine (`base_model` / `seed` / `prompt_hash` / `quality_metrics`)
      — `ContentPillars::Photo.import_render` is the single choke point both producers call
      (`Growth::ContentGenerator`, `Growth::RenderSalvage`), and `ContentPillars::PhotoProvenance`
      records the attribution the run actually carries. NOTE: the spine the task assumed does not
      exist in the data — `pipeline_runs.variables` holds only `sync_producer` on the growth path
      (10 of 457 runs carry a seed), so `base_model`/`seed` are omitted when absent rather than
      invented. Backfilling the spine itself is a separate change.
- [ ] 1.4 Constraint (phase 2, after backfill): `synthetic` is NOT NULL
      — deliberately deferred. The column stays nullable so an unmarked creation path shows up as
      `NULL` on the ops board (`photo-provenance-unmarked`, warn) instead of raising inside a
      render or the legacy candidate path. Constrain once no creation path can write NULL.

## 2. Embed machine-readable provenance in the asset
- [ ] 2.1 Write `digitalSourceType=trainedAlgorithmicMedia` into each published asset at creation (XMP/IPTC; C2PA if a signer is available)
- [ ] 2.2 Spec that the marker survives the NAS → served-URL path (the bytes served, not the local copy, are what Meta reads)
- [ ] 2.3 Prove it on one real asset: pull the published bytes and read the marker back out

## 3. Fail-closed publish gate
- [ ] 3.1 Publish path asserts the mark; marks in-flight when missing; blocks only when marking fails
- [ ] 3.2 rspec: an unmarked photo never reaches `Instagram::Client#create_post`
- [ ] 3.3 rspec: a marked photo publishes unchanged (no behaviour regression)

## 4. Surface disclosure
- [ ] 4.1 Caption generation carries the disclosure, or documents reliance on the platform label once metadata is readable
- [ ] 4.2 Post preview shows the synthetic marker

## 5. Verify and close
- [ ] 5.1 Confirm a newly published asset carries a readable marker end-to-end
- [ ] 5.2 Close `ai-content-disclosure-absent` on live evidence (not on the code landing)
- [ ] 5.3 Update `openspec/specs/content-provenance/spec.md` on archive

## Note
Do not begin until this proposal is approved. The approval gate is the founder's (the agent);
the implementation should run through the repo's normal worker path, not ad-hoc from a session.