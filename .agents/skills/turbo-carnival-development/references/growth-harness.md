# Growth Harness — concrete build reference

Built a self-improving follower-growth loop for turbo-carnival as a new pack
that reuses the existing persona → caption → schedule → Instagram → insights
pipeline. Concrete wiring from the original session (2026-08-20).

## Goal configuration

Gold default: 1,000 followers within 365 days (deadline defaults to
`created_at + 365.days`). Knobs on the goal row: `posts_per_day`,
`max_posts_per_day` (default 3), `hashtag_count` (default 10), and
`review_interval_days` (default 7).

## Tables (migration)

- `growth_goals` — persona_id, target_followers, deadline, start_followers,
  posts_per_day, max_posts_per_day, hashtag_count, review_interval_days,
  last_reviewed_at, status (active/paused), strategy_config (jsonb).
- `growth_snapshots` — goal_id, followers, taken_at.
- `growth_decisions` — goal_id, snapshot_id (nullable), action, reason,
  from_values (jsonb), to_values (jsonb), decided_at.

## Models (namespace `Growth::Goal` etc.)

Arithmetic lives on the goal for pure-Ruby testability:
- `required_daily_growth` = `(target - latest) / days_remaining`
- `average_daily_growth` = `(newest - oldest).to_f / days_between` (nil if <2 snapshots)
- `traj_ratio` = `average / required` — the brain's trigger metric
- `projected_completion_date` = now + `remaining / pace` (guards `.positive?`)

## Services

- `Growth::MetricsCollector#collect` → `Instagram::Client#followers_count`
  (Graph API: `GET /{account_id}?fields=followers_count`). On any failure do
  NOT raise out of the loop — record a `skip_data` decision and return nil.
- `Growth::CadenceEngine#sync` →
  target = `effective_posts_per_day * LOOKAHEAD_DAYS(7)`; call
  `PostAutomation::AutoCreateNextPost` until shortfall met or it fails; on
  failure record a `cadence_blocked` decision (don't return a silent 0).
- `Growth::StrategyBrain#review(force:)` → skip unless interval elapsed or
  `force: true`; `ratio < 0.75` → escalate (posts_per_day+1 toward max, then
  hashtag_count+5 toward 30); `ratio > 1.5` → reduce posts_per_day; else hold.
  Record every change via `Growth::Decision.create!`.

## Rails wiring

- Routes: `get "growth"`, `post "growth/:goal_id/sync_cadence|snapshot|review"`.
- Controller `GrowthController` (index + three POST actions that redirect to
  `/growth` with flash notices). `application_controller.rb` stays a bare
  `ActionController::Base`.
- Dashboard template: Tailwind cards; mirrors the persona-show/gap-analysis
  design system (zinc palette, `Catalyst::CardComponent`).

## Cron wrapper (`bin/growth_harness.sh`)
Source RVM, `rvm use 3.4.5`, then run three rake tasks (cadence → snapshot →
review). The review task self-gates on its interval; hourly is safe. Logs to
`log/growth_harness.log`.

## Verified behaviors
- `growth:run_all[Sarah]` end-to-end: goal auto-created, snapshot degraded
  gracefully (expired token), brain returned `need_data`.
- Synthetic backlog goal (stagnant) → ratio 0.07 → escalated 1→2 posts/day,
  decision row recorded.
- Synthetic on-track goal → ratio 1.23 → `hold`, no spurious decision.
- Interval guard → `{view: skip, next_review_at: ...}` when reviewed recently.

## Blocking issues surfaced (fix constants, not harness)
1. Instagram access token expired (Graph API `code 190, Session has expired`)
   — refresh in `config/credentials/development.yml.enc`.
2. Gemini caption key invalid (`key '00437451bb92cd000...' is not valid`) —
   blocks `AutoCreateNextPost` so cadence stays empty; correct `.env`
   `GEMINI_API_KEY`.

## Engagement measurement forensics — verify before concluding

Run these before stating any reach/engagement trend. The table holds fixtures, and the
metrics accumulate after publication, so both a raw aggregate and a recent-vs-lifetime
comparison will mislead.

**Real posts only.** `status='posted'` is not publication; a real post carries a provider id:

```sql
SELECT count(*) AS real_posts, count(*) FILTER (WHERE reach IS NOT NULL) AS with_reach,
       sum(likes_count) AS likes, sum(comments_count) AS cmts, sum(saved_count) AS saves,
       min(reach) AS minr, max(reach) AS maxr, round(avg(reach)::numeric,1) AS avgr
FROM scheduling_posts WHERE status='posted' AND provider_post_id IS NOT NULL;
```

Measured: 143 real posts -> 16 likes, 0 comments, 2 saves; reach 1..20, mean 7.8.

**The fixture rows.** 65 rows are seed/test data and must never enter a performance read:

```sql
SELECT caption, count(*), count(photo_id) AS with_photo,
       min(posted_at)::date, max(posted_at)::date, count(insights_updated_at) AS with_insights
FROM scheduling_posts WHERE status='posted' AND provider_post_id IS NULL GROUP BY 1;
```

`caption='test'`, 65 rows, ALL carry a `photo_id`, `posted_at` 2026-08-18..21,
`insights_updated_at` NULL on every one, and `reach = 1000` (a sentinel) on every one —
~2,180 likes between them. They PASS `WeeklyReview#posted_posts` (which filters `photo_id` +
`status` only) and are excluded by `GateRead` (`insights_updated_at IS NOT NULL`) and by the
7-day review window. Key insight-derived reads on `insights_updated_at IS NOT NULL` so they
can never leak in; a bare `reach IS NOT NULL` filter includes them.

**Volume curve — the cadence knee.** Bin MATURE days (posted >= ~12 days ago, so reach has
settled) by posts/day:

```sql
SELECT posted_at::date AS d, count(*) AS posts, sum(reach) AS total,
       round(avg(reach)::numeric,2) AS avg_per_post
FROM scheduling_posts
WHERE status='posted' AND provider_post_id IS NOT NULL AND reach IS NOT NULL
  AND posted_at >= '2026-08-22' GROUP BY 1 ORDER BY 1;
```

| posts/day | total reach/day | reach per post |
|---|---|---|
| 1 | 11.2 | 11.2 |
| 2 | 17.3 | 8.7 |
| 3-4 | 22.8 | 6.5 |
| 5-9 | 22.3 | 3.0 |

Total reach saturates near ~22/day; per-post reach falls 4x across the bands;
`r(posts/day, per-post reach) = -0.775` over 22 days. Age is NOT the driver: the OLDEST
high-volume days (8-9 posts/day) read per-post reach 2.25-3.0, the same as recent, while NEWER
1-post days read 11-13 — age works against a "declining" reading. So a recent-vs-lifetime
comparison (`7.77 all-time vs 2.76 over 14d`) is a volume confound, not a trend; the same
trap applies to any per-post metric on a young post.

**Followers** come from `growth_snapshots` (hourly writes): `max(followers)` per
`taken_at::date` over the window. Measured: flat 150-158 across 33 days, no trend.

## There is NO per-post follower/non-follower split (measured 2026-10-19)

**Do not design a per-post `non_follower_reach` metric — the platform cannot answer it.** The
Graph API refuses a `follow_type` breakdown on MEDIA-level insights, on every version and metric
tried (media 17917610733255110, a real still; and a real reel):

| probe | result |
|---|---|
| `/{media_id}/insights?metric=reach&breakdown=follow_type` | 400 `(#100) Incompatible breakdowns (follow_type) for metric (reach)` |
| same + `metric_type=total_value` / `period=lifetime` | 400, identical message |
| API versions v19.0, v20.0, v21.0, v22.0, v23.0, v24.0 | 400 on all six |
| 11 metrics x `breakdown=follow_type` (`total_interactions, impressions, profile_activity, navigation, follows, profile_visits, replies, saved, shares, likes, comments`) | 400 on all |
| `reach` x `breakdown=surface_type` / `action_type` | 400 |
| still media AND reel media | both refused |
| ACCOUNT-level `/{account_id}/insights?metric=reach&period=day&metric_type=total_value&breakdown=follow_type` | **200, works** |

`follow_type` IS listed as a valid breakdown *name* for media insights (`breakdown[0] must be
one of: follow_type, surface_type, action_type, story_navigation_action_type`), so the 400 is a
metric-compatibility refusal, not a typo — there is no media metric it can be paired with.

**The positive control that makes this a verdict rather than a guess:** on the SAME media,
`metric=profile_activity&breakdown=action_type` returns **200**. Media-level breakdowns are
live and the endpoint accepts them; this specific pairing is illegal. Without that control the
refusal is indistinguishable from "breakdowns are disabled on this endpoint", which is a
different and wrong conclusion — run a sibling combination the docs say works before calling
any refusal a platform limit. Confirmed independently by the official reference, whose media
Breakdowns table lists exactly two values (`action_type` for `profile_activity`,
`story_navigation_action_type` for `navigation`) and annotates `reach` with none.

Reproduce (read-only, no writes):

```bash
# in a tmp/ script, run with: bin/rails runner tmp/probe.rb
resp = Faraday.new(url: "https://graph.facebook.com/v20.0") { |f| f.request :url_encoded; f.response :json }
         .get("#{media_id}/insights") { |r| r.params["metric"]="reach"; r.params["breakdown"]="follow_type"; r.params["access_token"]=token }
```

**What IS available per post** (v20.0, measured): `reach`, `impressions`, `likes`, `comments`,
`saved`, `shares`, `replies`, `total_interactions`, `navigation`, `profile_activity`, and on
FEED media also `follows` + `profile_visits`. On REELS media those last two are refused:
`The Media Insights API does not support the profile_visits, follows metric for this media
product type` — so a reel has NO per-post follows/profile_visits either.

**The account-level call's SHAPE is the trap.** Measured across 40 consecutive one-day windows:
37 returned `total>0` WITH a `results` array, 3 returned `total=0` with none, and **0** returned
`total>0` without one. So an absent `results` array simply means the window had zero reach —
nothing was reached, so there was nothing to split. Two consequences: `growth_snapshots` writing
`0/0/0` for a zero-reach day is a REAL measurement, and
`Instagram::Client#account_reach_breakdown` ("an absent dimension is a measured zero") is sound —
do not read a missing `results` key as a fabricated split. Also measured: account-level `reach`
accepts `period=day` only (`period=lifetime` -> 400), a `since`/`until` window must be <= 30 days,
and the account-level breakdown enum is `country, city, age, gender, follow_type,
media_product_type, contact_button_type`. A no-window call is legitimate: it returns the split
whenever the default window has reach.

**Consequence.** Non-follower reach exists ONLY as an account-level, per-DAY measurement
(`growth_snapshots.non_follower_reach`, via `Instagram::Client#reach_attribution`). Per-post you
have total `reach` and, on stills, `follows`/`profile_visits`. Attaching the account/day split
to a post is a DERIVATION, not a measurement: if it is ever recorded, label it as attributed
(a method + source column) and never write it into a column whose name implies the platform
measured it per post.

## Per-post `views` IS available and we were not collecting it (2026-10-19)

`views` (Meta's promoted primary metric, which replaced impressions/plays) is in the media
insights metric enum and answers per post through the SAME call `CollectPostInsights` already
makes. Verified live: metric=`views,reach,likes,comments,saved` returned views 11/7/10/3/4/6
against reach 6/5/6/3/4/6 for the 6 newest posts. We collected reach, likes, comments and saved
and were **throwing `views` away**. Add it to any per-post signal set.

## ONE unsupported metric fails the WHOLE insights call (2026-10-19)

`follows` and `profile_visits` answer only for FEED media. Against the account's reel:

    400 code 100 "The Media Insights API does not support the follows, profile_visits
    metric for this media product type."

and -- the part that bites -- asking for them ALONGSIDE supported metrics fails the entire
request: `likes,comments,reach,saved,shares,views,follows,profile_visits` -> 400 where
`likes,comments,reach,saved,shares,views` -> 200 on the SAME media. A metric list is not a
bag of independent asks. Two consequences:

1. Never append a FEED-only metric to a shared metric list -- it costs the metrics that did
   work, on every non-FEED media.
2. `CollectPostInsights` maps code 100 to its TERMINAL verdict (`insights_unavailable_at`,
   which parks the row for 30 days). Routing a FEED-only refusal through that path would
   mark every reel permanently uncollectable and stop its `reach` refreshing at all. A
   refusal on a secondary call means "not applicable" -> nil, never "unavailable".

The collector therefore makes two calls: `likes,comments,reach,saved,shares,views` always,
and `follows,profile_visits` only when `scheduling_posts.reel_path` is blank (a known reel
is not asked, saving the call; an unmarked reel is asked, refused, and handled).
`Growth::RenderReach` groups reach/views by render through
`renders.image_candidate_id` -> `photos.image_candidate_id` -> `scheduling_posts.photo_id`,
so reels (no photo) are absent from that read rather than attributed to a guess.

## Do NOT try to read the Instagram WEB insights page by copying its text (2026-10-19)

The desktop surface `instagram.com/accounts/insights/content/?metric=…&timeframe=30&view_type=card`
is login-walled (unauthenticated GET hard-redirects to `accounts/login/?next=…`), and the HTML is
the app SHELL — grep of a full 610 KB paste returned 0 hits for `non_follower`, `follow_type`,
`Accounts reached`, `breakdown`, `total_value`; the values arrive via an internal GraphQL/Relay
call after load.

Copying the rendered text is not a usable read either, measured: two copies of the SAME url gave
sequences offset by 20 entries (`new[:10] == old[20:30]`, 23 overlapping entries byte-identical),
so the copy order is not the visual order on that autoloading list; the lists carry **no per-card
post identifier**; and neither matched the API's per-post `views` for the same posts. A manual
read must be PER POST from that post's own insight panel, pasted with its date or caption.

Calibration that DID work, and is the way to validate any such paste: the `metric=interactions`
page reproduced our own `likes+comments+saved` exactly (`3,0,1,4,2` at the posts of 10-05 11:00
and 10-04 14:01/11:01/09:00), and `--` on that page means zero.

**The web Content-insights surface is login-walled, and a UI number must be CALIBRATED before
it is trusted.** `instagram.com/accounts/insights/content/?metric=…&timeframe=30&view_type=card`
is the desktop per-post insights list; the URL's `metric=` parameter switches which per-post
metric the cards show. Unauthenticated it hard-redirects to `accounts/login/?next=…`, so there is
**no unauthenticated path** to any of this — the split, and per-post insights generally, are
served by an internal endpoint behind a session, never by the public Graph API.

Its cards render a **bare number with no per-post identifier**, so a pasted list is not
attributable to posts until it is calibrated. Calibrate by reproducing the page from our own
data rather than by eye: with `metric=interactions` the page's `--` placeholders mean ZERO, and
its numbers are exactly our per-post `likes + comments + saved` (the page's `3, --, 1, 4, 2`
matched our sequence `3, 0, 1, 4, 2` across four consecutive posts). That metric therefore adds
nothing we do not already hold — a matching subsequence proves what the page is showing; a
mismatch means a different subset or a different definition, and neither is safe to assume.

**`views` IS collectable per post, and we do not collect it.** `views` is in the media-insights
metric enum and answers for stills and reels alike — measured 11, 7, 10, 3, 4, 6 for the six
newest posts where our `reach` column reads 6, 5, 6, 3, 4, 4. It is now Meta's promoted primary
metric (it replaced impressions and plays), it arrives on the insights call we already make, and
it is missing from our data: collect it alongside `reach`, `follows` and `profile_visits`.

**Unresolved — do not paper over it.** The page's `metric=views` numbers do NOT match the API's
per-post `views` (the page's newest entry is 2 where the API says 11, and `11` appears nowhere in
the page's list). Either the page lists a different SET of posts (it showed 43 where our 30-day
window holds 81 — plausibly only content that still exists, since some posts answer 400/code 100
as deleted or inaccessible) or its `views` is a different definition from the API's. A single
post's DETAIL panel — which carries the post and its numbers together — is what resolves it; a
bare card list cannot.