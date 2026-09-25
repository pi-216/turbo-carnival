# Change: Pivot the growth arm to a discovery surface — Reels cut from renders we already produce

## Why

The pre-registered GO/PIVOT/KILL gate (`Growth::GateRead`, registered on the ops board as
`growth-strategy-gate`) names **distribution/reach** as its pivot candidate. Until 2026-09-24
the repo held only *per-post* reach (`scheduling_posts.reach`), and a sum of per-post reach
cannot separate "our followers see every post" from "strangers find us" — two different
businesses with different fixes.

That number has now been MEASURED, and it is not a proxy. The account-level insights endpoint
answers `reach` with `breakdown=follow_type` (the media-level endpoint rejects the breakdown
with code 100). Measured 2026-09-24: `reach=6`, `FOLLOWER=6`, and **no `NON_FOLLOWER` row at
all**, with `profile_views=0`. The platform is stating that nothing outside the follower list
is being shown these posts. Corroborating, from the DB: total weekly reach is flat at ~139–149
whether the account publishes 23 posts or 42 (per-post reach falls ~4x as volume rises), and
followers have sat at 157 for ten days while per-post reach decayed 3.2x against the
pre-harness era on unchanged cadence.

The thesis's mechanism is **publish → discovery → follows**. With zero non-follower reach the
middle step does not exist on the surface this harness publishes to, so every content, caption,
hashtag and persona lever is inert *by construction* — it cannot move a number that is zero
for a distribution reason. The gate's own pivot candidate is therefore what fires, and the
growth thesis needs a surface that has a discovery step at all.

Reels are that surface, and they are publishable on the **same account and the same API**
(`media_type=REELS`) with no credential and no platform-side change — so this is a build the
operating agent owns, not an enablement ask on a human.

## What Changes

- A new asset step, `Growth::ReelBuilder`: a short vertical (1080x1920) H.264 MP4 composed from
  renders the harness already produces, with a slow zoom per still and crossfades. The 4:5
  render (816x1024) is PADDED onto a blurred, cover-scaled copy of itself rather than centre
  cropped, so a portrait is never cut. The IPTC synthetic mark is embedded in the container's
  own metadata and read back from the bytes.
- `Instagram::Client#create_reel`: a `REELS` video container (`video_url`, `media_type=REELS`),
  reusing the existing caption, AI self-disclosure (with the same fallback), single-use
  container and publish-retry semantics. Video containers are *transcoded*, so the ready-check
  is bounded at 30 x 10 s rather than the image path's 10 x 3 s.
- The image path's request is unchanged by construction: `media_type` is sent only when it
  differs from the default.
- The serving step a video container needs: `scheduling_posts.reel_path` (NULL = still, so
  every existing row keeps its meaning), `get /media/reels/:id => media#reel` (keyed on the
  POST, so the still path's withhold rule carries over unchanged), and
  `Scheduling::Commands::GeneratePublicReelUrl`, fail-closed on the asset's own bytes. A REELS
  post may be scheduled with no photo, which also keeps reels out of
  `Growth::GateRead#cohort_size` — the still-based cohort the pre-registration measures.
- `bin/reel_rail_smoke.sh` proves the rail end to end against the live tunnel (build → URL →
  fetch → marked bytes served → non-reel ids 404 → no debris).

Still **out of scope** (tracked in `tasks.md`, not silently omitted): wiring a reel into the
publishing rail, which is the ARM step and is sequenced after the 2026-10-05 read below.

## Metric and sequencing

- The arm's success metric is the already-collected `growth_snapshots.non_follower_reach`.
  Engagement is deliberately NOT the metric — an account with no discovery cannot produce an
  engagement signal, and reading engagement here would re-derive the same flat zero.
- **The metric must be read against a BASELINE, not against zero (measured 2026-09-25).** The
  original criterion was "`> 0` means discovery happened", and that was sound while the counter
  sat at a hard zero (33 of the first 35 measured snapshots). It no longer is: the newest two
  snapshots read `non_follower_reach = 1` against `follower = 6` / `total = 7`
  (`profile_views = 0`), so **the criterion is satisfied before the arm exists**. A post-arm read
  of `> 0` therefore cannot distinguish the arm's effect from this ambient value, and citing
  `> 0` as the arm working would be a false positive that no other signal contradicts. The
  baseline is recorded at arm time (the pre-arm window's non-follower reach and its share of
  total reach) and the arm is judged on non-follower reach EXCEEDING that baseline over the
  post-arm window, with the ambient value reported beside it.
- `Growth::GateRead` now emits the split itself (`discovery=` plus a DISCOVERY clause in
  `reason`), so the read that will judge the growth thesis at 2026-10-05 carries the same number
  this arm is judged on, instead of leaving a reader to query another table.
- **Sequencing constraint (recorded before any publish):** the arm is NOT armed on the rail
  until after the 2026-10-05 13:00Z gate read. `Growth::GateRead#cohort_size` counts posts in
  the review window that join a `photo` and carry collected insights, so publishing a new
  format into that window injects an uncontrolled variable into the very cohort the pivot was
  pre-registered against. The machinery is built now so the arm can fire immediately after the
  read; the read is not contaminated to get there.

## Impact

- Affected specs: `distribution` (ADDED).
- Affected code: `packs/growth_harness/app/services/growth/reel_builder.rb` (new),
  `packs/scheduling/app/clients/instagram/client.rb` (`create_reel`, generalised container),
  `packs/scheduling/app/commands/scheduling/commands/generate_public_reel_url.rb` (new),
  `app/controllers/media_controller.rb` + `config/routes.rb` (`media/reels/:id`),
  `packs/scheduling/app/models/scheduling/post.rb` (`reel?`, photo optional for a reel).
- One additive migration: `scheduling_posts.reel_path` (nullable; no existing query changes).
- No persona or prompt change, no rendering change.
- Reversibility: nothing on the live rail references these classes yet, so dropping them
  restores the prior behaviour exactly.
- Requires `ffmpeg` on the publishing host (verified present: 8.0.1). The builder raises rather
  than producing a partial asset when it is absent.