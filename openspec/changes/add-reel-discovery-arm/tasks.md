# Tasks — add-reel-discovery-arm

## 1. The motion asset (built)
- [x] 1.1 `Growth::ReelBuilder` — compose N renders into a 1080x1920 H.264/yuv420p MP4 with a
      per-still slow zoom and crossfades. Blur-pad the 4:5 render, never centre-crop it.
      — `packs/growth_harness/app/services/growth/reel_builder.rb`. Verified on the live render
      corpus (photos 362/363/364): build 2.4 s, ffprobe `h264 1080x1920 yuv420p 30/1`,
      8.000 s for 3 photos x 3 s minus 2 x 0.5 s crossfade, 2.5 MB.
- [x] 1.2 Embed the IPTC synthetic mark in the container and read it back from the bytes
      (`Growth::ReelBuilder.marked?`). — Verified: `ffprobe -show_entries format_tags` returns
      `Iptc4xmpExt:DigitalSourceType = http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia`.
      THESIS red line: no unmarked asset is publishable.
- [x] 1.3 `+faststart` so the moov atom precedes mdat and the platform can fetch progressively.
      — asserted in `spec/services/growth/reel_builder_spec.rb`.
- [x] 1.4 Spec: 9 validation/behaviour examples plus integration coverage of a real clip
      (duration arithmetic, geometry, pix_fmt, marker, faststart). Skips when ffmpeg is absent.

## 2. The publish path (built)
- [x] 2.1 `Instagram::Client#create_reel` — `video_url` + `media_type=REELS`, AI
      self-disclosure with the still path's fallback, shared publish retry.
      — `packs/scheduling/app/clients/instagram/client.rb`.
- [x] 2.2 Bounded video ready-check (30 x 10 s) instead of the image path's 10 x 3 s, because a
      video container is transcoded rather than fetched.
- [x] 2.3 Assert the still path's container request is unchanged (no `media_type`, no
      `video_url`) — 5 new examples in `spec/services/scheduling/instagram_client_spec.rb`.

## 3. Governance record (built)
- [x] 3.1 Decision recorded on the ops board before any build, with the measured evidence and
      the pre-registered metric (`non_follower_reach > 0`).
      — board item `zero-engagement-at-production-rate`, note 2026-09-24.
- [x] 3.2 This change proposal, with the sequencing constraint written down before any publish.

## 4. Serving path (built 2026-09-24)
- [x] 4.1 Serve the reel MP4 over the public HTTPS URL the container needs, mirroring
      `MediaController#photo`'s withhold rule (serve only while a post references the asset)
      rather than exposing an enumerable path. — `get /media/reels/:id => media#reel`, keyed on
      the POST id, so a reel is servable exactly while its post row exists. Verified live through
      the tunnel: `200`, `video/mp4`, served bytes byte-identical to the built file and carrying
      `Iptc4xmpExt:DigitalSourceType`; a still post id and an unknown id both `404`.
- [x] 4.2 Decide the record that owns a reel so the queue, the release plan and insights
      collection treat it as a first-class item. — a `reel_path` column on `scheduling_posts`
      (NULL = still, so every existing row keeps its meaning). A REELS post may be scheduled with
      NO photo: its published media is the composed clip, and keeping it out of the photo join
      also keeps it out of `Growth::GateRead#cohort_size`, which is the still-based cohort the
      pre-registration measures.
- [x] 4.3 `Scheduling::Commands::GeneratePublicReelUrl` — the twin of `GeneratePublicPhotoUrl`,
      fail-closed on the asset's own bytes (missing file / missing mark / no public base).
- [x] 4.4 `bin/reel_rail_smoke.sh` — one command that builds a real clip from real renders, mints
      the URL, fetches it over the LIVE tunnel, asserts the served bytes are the marked ones, and
      removes its throwaway post (trap-guarded). Run it before arming.

## 5. Arm the rail (BLOCKED on the 2026-10-05 gate read, by design)
- [ ] 5.1 Publish the first reel only after the 2026-10-05 13:00Z `Growth::GateRead`.
      Reason: `cohort_size` joins `photo` and requires collected insights inside the review
      window, so a new format published into the window confounds the pre-registered cohort.
- [ ] 5.2 First publish is a single reel, watched end to end (container FINISHED -> publish ->
      insights), then compare `growth_snapshots.non_follower_reach` against the **baseline recorded
      at arm time**, not against zero — see 6.2 and the Metric section.

## 6. Pre-arm re-verification (re-run before arming; record the numbers)
- [x] 6.2 BASELINE recorded 2026-09-25T06:30Z, before arming: of the 35 measured snapshots since
      2026-09-24T05:36Z, 33 read `non_follower_reach = 0` and the newest two read `1`
      (follower=6, total=7, `profile_views=0`). So the arm's original criterion (`> 0`) is already
      satisfied pre-arm and cannot be the arm's evidence; the pre-arm baseline it must EXCEED is
      non-follower reach 1 of ~7 per snapshot. Re-measure at arm time — this number is the one the
      arm is judged against, so a stale baseline invalidates the read.
      `Growth::GateRead` now emits the same split (`discovery=` + a DISCOVERY clause) on every
      read.
- [x] 6.1 `bin/reel_rail_smoke.sh` re-run 2026-09-24 by the ops pass, BEFORE the read rather
      than on the day: PASS — 2 343 443 bytes, `h264 1080x1920 yuv420p`, duration 8.000 s,
      IPTC mark readable from the file, served over the LIVE tunnel as `video/mp4` with
      byte-identical length, non-reel post id 404, cleanup left `POSTS 300 REELS 0` (no
      debris). So the rail is publishable as of that date; if this is stale when the arm is
      armed, re-run it — that is the whole point of having one command for it.
- [x] 5.3 Add an ops check that reads the arm's own state (built-but-unarmed -> armed ->
      measured) so the pivot cannot stall silently between passes. — `check_reel_arm_stall`
      (`bin/tc_ops.py`). Tightened 2026-09-24: the caller scan keys on the PUBLISH call
      (`create_reel`) alone, not on any reference to the builder — the new URL command names
      `Growth::ReelBuilder` in a failure message, and the wider pattern consequently reported the
      arm as ARMED while nothing published, i.e. it silenced the one check that catches a dropped
      pivot. Declared-but-inert silence is asserted in the selftest.