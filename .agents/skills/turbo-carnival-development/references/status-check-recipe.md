# Status Check Recipe — "how are we doing" in one pass (verified 2026-08-21)

The fastest way to answer "how are we doing" for the turbo-carnival Instagram
growth harness, without rediscovering the model layout each time.

## Model map (do NOT guess bare constants)

Top-level `app/models/` only holds ContentSuggestion, GapAnalysis, Vote;
`Persona` lives in `packs/personas`. Everything harness-related is
pack-namespaced — bare `Post`, `SchedulingPost`, `GrowthSnapshot`,
`GrowthReview` all raise NameError:

- `Scheduling::Post` — cols: status (posted/failed/scheduled), scheduled_at,
  posted_at, photo_id, caption, provider_post_id, likes_count, comments_count,
  reach, engagement_rate, caption_metadata (jsonb).
- `Growth::Goal` — persona_id, instagram_handle, target_followers, deadline,
  start_followers, posts_per_day, status. Keyed by **persona_id**.
- `Growth::Snapshot` — cols: **goal_id** (not persona_id!), followers,
  taken_at. Query via the goal: `Growth::Snapshot.where(goal_id: goal.id)`.
- `Growth::Review` — goal_id, reviewed_at, verdict, followers_delta,
  required_daily, measured_daily, trajectory_ratio, recommendations,
  applied_changes (jsonb).
- Photos: **`ContentPillars::Photo`** — bare `Photo` raises NameError; link
  via `Scheduling::Post.reflect_on_association(:photo).class_name`.
- `Growth::Goal` has **NO `declining?` method** (NoMethodError, seen
  2026-09-04) — `declining?` is a StrategyBrain-side predicate. Goal-level
  checks use `goal.traj_ratio < 0` / `goal.average_daily_growth < 0`.

## Probe script pattern

Inline `rails runner '...'` mangles multi-line Ruby (%w[], rescue modifiers,
heredocs) — write a file and run it instead:

```bash
cd /home/tim/source/activity/turbo-carnival
bin/rails runner /tmp/status_check.rb
```

Skeleton:

```ruby
p = Persona.find_by(name: "Sarah")
goal = Growth::Goal.where(persona_id: p.id).first
puts "GOAL: #{goal.attributes.to_json}"
puts "POSTS by status: #{Scheduling::Post.where(persona_id: p.id).group(:status).count}"
Scheduling::Post.where(persona_id: p.id, status: "scheduled").order(:scheduled_at)
  .each { |x| puts "id=#{x.id} at=#{x.scheduled_at} photo=#{x.photo_id}" }
Growth::Snapshot.where(goal_id: goal.id).order(taken_at: :desc).limit(10)
  .each { |s| puts "#{s.taken_at} followers=#{s.followers}" }
Growth::Review.where(goal_id: goal.id).order(reviewed_at: :desc).limit(2)
  .each { |r| puts "verdict=#{r.verdict} delta=#{r.followers_delta} ratio=#{r.trajectory_ratio}" }
```

Note: `rails runner` can exit 0 on error — read the output, not the exit code.

## Where cron state lives

- Cron run reports: `$HERMES_HOME/profiles/turbo-carnival/cron/output/<job_id>/<timestamp>.md`
  (brain job 43b0d5c4446d = hourly; watchdog 31c2d0bc8261; weekly review 8d3ac21799d5)
- Watchdog log: `log/overnight_watchdog.log` in the app dir
- Scheduled-posting log: `log/scheduled_posting.log`

## Telemetry gotchas (verified 2026-09-03/04)

- **Scheduler `idle` ≠ GPU free.** `gpu_scheduler.py status` sees only claimed
  jobs; unregistered VRAM holders recur (prx-tg training 13GB/89%, then
  stratum-hq python3.14 20.3GB/0% util, both same day while reporting idle).
  Cross-check `nvidia-smi --query-compute-apps=pid,used_memory,process_name`
  before reading the GPU as available. 20+ consecutive hourly
  `comfyui_unclaimed` decisions + `ensure` exit 2 = unregistered-tenant
  blocker, not harness bug. The brain also sweeps stale expired queue entries;
  the blockage clears only when the tenant exits.
- **PipelineRun `pending` is the normal state.** 322/389 runs stuck pending
  forever even after successful render→import→schedule (quality_metrics
  populated on the very runs still marked pending). Do NOT read run status as
  throughput. Read `group(:status).count` as context only; real signal =
  scheduled posts ahead + quality_metrics scores.
- **Failed posts diagnostic:** all 64 `failed` posts have nil `posted_at` and
  nil `provider_post_id` — they are the pre-Aug-28 bad-token era, NOT active
  failures. Live cadence = posted-by-day counts (recent: ~3-9/day).

## Render sweep progress (a background sweep is running — where is it?)

Count the artifacts on disk, not the runner's log lines: the log is per-render
and subject to buffering, while the files are the durable signal. Point `R` at
the run root the sweep was given:

```bash
R="/home/tim/Documents/obsidian/04 - projects/turbo-carnival/elo/<run-root>"
echo "renders: $(find "$R" -name '*.png' -not -path '*/pairs/*' | wc -l)/<expected>"
echo "sheets : $(find "$R/pairs" -name '*.png' 2>/dev/null | wc -l)/<expected>"
pgrep -f 'replicate_e[3]' >/dev/null && echo "job: running" || echo "job: finished"
```

**Bracket one character of the pgrep pattern** (`replicate_e[3]`, `tc_rend[e]r`).
A bare pattern also matches the `pgrep` invocation itself, so it always reports
"running" — a self-match that reads as a stuck job when the job is gone.

For what the GPU is actually doing, read ComfyUI's own queue rather than the
runner's stdout:

```bash
python3 -c "
import json,urllib.request as u
q=json.load(u.urlopen('http://127.0.0.1:8188/queue',timeout=15))
print('running=%d pending=%d'%(len(q.get('queue_running',[])),len(q.get('queue_pending',[]))))
for it in q.get('queue_running',[]):
    print('ckpt:',it[2].get('87',{}).get('inputs',{}).get('ckpt_name'))
"
```

Node 87 is the checkpoint token, so this confirms which arm is mid-render.
`running=0 pending=0` is the state to require before starting another run —
it means the sweep finished *and* the card drained, so no arm of the next run
is confounded by a co-resident job.
