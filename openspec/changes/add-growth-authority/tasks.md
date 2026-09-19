# Tasks — add-growth-authority

## 1. Verdict + gate model
- [ ] 1.1 Add `resource_blocked` and `goal_unattainable` to `Growth::Review::VERDICTS`
- [ ] 1.2 Add `strategy_exhausted`, `pivot_applied`, `revert_pivot` to `Growth::Decision::ACTIONS`
- [ ] 1.3 Add named threshold constants + consecutive-review counter to a new
      `Growth::Authority` service (GO/BEHIND/PIVOT/KILL, RESOURCE_BLOCK_RATIO,
      UNATTAINABLE_DIVERGENCE, pivot/kill persistence counts)

## 2. Wire into the loop
- [ ] 2.1 `WeeklyReview#classify` delegates to `Growth::Authority` for verdict + counters
- [ ] 2.2 `StrategyBrain#hold_declared` persists `strategy_exhausted` when knobs are maxed
      and `traj_ratio < ESCALATE_THRESHOLD`
- [ ] 2.3 Resource-blocked attribution: count `comfyui_unclaimed`/`cadence_blocked` density
      over the review window and route to `resource_blocked`

## 3. Pivot + kill execution
- [ ] 3.1 Implement `Growth::Authority#mandate_pivot` — select + apply a structural lever,
      record `pivot_applied` with attributable identity
- [ ] 3.2 Extend `evaluate_previous_gates` to revert a failed pivot (`revert_pivot`)
- [ ] 3.3 Implement `goal_unattainable` halt: stop cadence production, surface to operator

## 4. Tests + validation
- [ ] 4.1 Spec `spec/services/growth/authority_spec.rb` for GO/BEHIND/PIVOT/KILL counters
- [ ] 4.2 Spec `strategy_brain_spec.rb` for the `strategy_exhausted` persistence
- [ ] 4.3 Spec `weekly_review_spec.rb` for `resource_blocked` + `goal_unattainable` verdicts
- [ ] 4.4 `openspec validate add-growth-authority --strict`