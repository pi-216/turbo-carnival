# Change: Add a decision-authority gate to the growth harness (GO / PIVOT / KILL)

## Why
The harness measures "on_track=false · ratio=0.10" every hour and every week verdicts
`behind`, but nothing in the codebase *mandates* a change when the trajectory is
persistently hopeless. The only terminal state is `declining` (net follower loss);
"persistently behind" (ratio 0.10 for 4 straight weekly reviews: 08-24, 08-31, 09-07,
09-14) has no concluding verdict, no structural pivot, no kill/halt. Meanwhile the sole
"behind" lever (cadence) is already maxed (3/3) and starved by GPU contention (310 of
the last 336 hours `comfyui_unclaimed`), and the "at-max-effort" state is never even
persisted — `hold_declared` returns a transient hash. The loop bleeds out silently.

## What Changes
- Add a **pre-registered GO / PIVOT / KILL trajectory gate** keyed to the weekly review
  cadence, with quantitative thresholds and consecutive-review persistence counters.
- Add a **`strategy_exhausted` persisted Decision** when all volume knobs are at max
  (closes the "silence as non-event" leak in `hold_declared`).
- Add a **`resource_blocked` verdict + attribution** when the render resource is the
  constraint (comfyui_unclaimed/cadence_blocked density), so a walled-off GPU is not
  re-read as a content-quality problem.
- Add a **`goal_unattainable` halt verdict** (the KILL arm) that surfaces to the operator
  and recommends re-target/retire when the catch-up treadmill diverges (required/measured
  multiple and consecutive-review counters met).
- Widen the PIVOT arm's **structural levers** (persona reweight, caption strategy,
  pipeline/base-model swap, posting shift) — pre-registered and reverted on gate failure.
- **BREAKING** (semantics): `Review::VERDICTS` gains `resource_blocked` and
  `goal_unattainable`; `Decision::ACTIONS` gains `strategy_exhausted` and `pivot_applied`.

## Impact
- Affected specs: new capability **`growth-authority`** (plus MODIFIED wire-in to the
  existing growth harness behaviors in `strategy_brain.rb` / `weekly_review.rb`).
- Affected code: `packs/growth_harness/app/services/growth/strategy_brain.rb`,
  `weekly_review.rb`, `packs/growth_harness/app/models/growth/{review,decision}.rb`.
- No destructive/external side effects; additive state + a halt condition.