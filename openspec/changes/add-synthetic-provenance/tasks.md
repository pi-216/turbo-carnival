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
- [x] 2.1 Write `digitalSourceType=trainedAlgorithmicMedia` into each published asset at creation (XMP/IPTC; C2PA if a signer is available)
      — `ContentPillars::PhotoAssetMarker` (commit 20e2589): an XMP packet with
      `Iptc4xmpExt:DigitalSourceType` + `xmpRights:Marked`, written into PNG
      (`iTXt` after IHDR) and JPEG (APP1 after SOI), atomically and idempotently.
      Called from `ContentPillars::Photo.import_render`, the single choke point
      both render producers use, so the file is marked before any post can
      reference it. `rails photos:embed_provenance` covers pre-existing assets
      (dry-run default; PHOTO_ID=/LIMIT= to scope). C2PA is not available (no
      signer), which is why the carrier is IPTC/XMP.
- [x] 2.2 Spec that the marker survives the NAS → served-URL path (the bytes served, not the local copy, are what Meta reads)
      — the served URL is a passthrough: `MediaController#photo` send_files
      `servable_file_path`, so the marked file IS the served byte stream. Asserted
      by reading the mark back from the public URL, not from the local file.
- [x] 2.3 Prove it on one real asset: pull the published bytes and read the marker back out
      — 2026-09-21: photo 334 (the asset behind post 328) marked via the rake
      task, then `https://carnival.pi216.ai/media/photos/334` fetched with curl
      after the post published (07:00:29Z): `digitalSourceType =
      http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia`,
      every PNG chunk CRC valid, pixel payload unchanged.

## 3. Fail-closed publish gate
- [x] 3.1 Publish path asserts the mark; marks in-flight when missing; blocks only when marking fails
      — `Scheduling::Commands::GeneratePublicPhotoUrl` (the last step before
      `SendPostToInstagram` on BOTH rails: the `SchedulePost` chain and
      `scheduling:post_scheduled`). Order: assert on the bytes the URL will serve
      → mark in flight → block only if the mark is still absent, naming the
      remedy. Verified it cannot strand the live queue: all 22 photos in the
      current queue + recent posts are PNG, writable and markable.
- [x] 3.2 rspec: an unmarked photo never reaches `Instagram::Client#create_post`
      — `spec/commands/scheduling/generate_public_photo_url_spec.rb`: an
      unmarkable asset fails the chain and `Instagram::Client.new` is never
      constructed (no post row is left behind).
- [x] 3.3 rspec: a marked photo publishes unchanged (no behaviour regression)
      — same file: a marked photo returns the tunnel URL, is not rewritten, and
      the full `SchedulePost` chain publishes with the expected `image_url` +
      caption.

## 4. Surface disclosure
- [ ] 4.1 Caption generation carries the disclosure, or documents reliance on the platform label once metadata is readable
- [ ] 4.2 Post preview shows the synthetic marker

## 5. Verify and close
- [x] 5.1 Confirm a newly published asset carries a readable marker end-to-end
      — post 328 published 2026-09-21T07:00:29Z with photo 334; the public bytes
      at https://carnival.pi216.ai/media/photos/334 read
      `digitalSourceType=trainedAlgorithmicMedia` (PNG chunk CRCs all valid,
      pixel payload unchanged). The gate itself marked nothing on this pass --
      photo 334 was marked by `photos:embed_provenance` before the post went out,
      so the publish rail consumed a marked asset.
- [x] 5.2 Close `ai-content-disclosure-absent` on live evidence (not on the code landing)
      — closed 2026-09-21 07:0xZ on the 5.1 evidence (published post + readable
      marker in the served bytes), with the DB half (1.1-1.3) already landed.
- [ ] 5.3 Update `openspec/specs/content-provenance/spec.md` on archive
      — archive-time step; 4.1/4.2 (surface disclosure) are the remaining open
      tasks of this change.

## Note
Do not begin until this proposal is approved. The approval gate is the founder's (the agent).

The original note also said implementation should run through "the repo's normal worker path".
Measured 2026-09-21: this repo has NO dev-worker path -- no PRD/board harness, no worker unit or
cron for it (grep for the term finds only this file and the ops board digest). Tasks 1.x had
already been implemented directly for the same reason, so 2.x/3.x were implemented and verified
directly too (commit 20e2589). If a worker harness is ever stood up for this repo, that is a
process change to make deliberately -- it is not a reason to leave a founder-approved disclosure
rail unbuilt.