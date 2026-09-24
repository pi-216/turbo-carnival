# Tasks — add-growth-authority

## 1. Verdict + gate model
- [ ] 1.1 Add `resource_blocked` and `goal_unattainable` to `Growth::Review::VERDICTS`
- [x] 1.2 Add `strategy_exhausted`, `pivot_applied`, `revert_pivot` to `Growth::Decision::ACTIONS`
      — verified present 2026-09-24 (`growth/decision.rb` ACTIONS).
- [ ] 1.3 Add named threshold constants + consecutive-review counter to a new
      `Growth::Authority` service (GO/BEHIND/PIVOT/KILL, RESOURCE_BLOCK_RATIO,
      UNATTAINABLE_DIVERGENCE, pivot/kill persistence counts)

## 2. Wire into the loop
- [ ] 2.1 `WeeklyReview#classify` delegates to `Growth::Authority` for verdict + counters
- [x] 2.2 `StrategyBrain#escalate` persists `strategy_exhausted` once the LIVE knobs are
      maxed (`posts_per_day == max_posts_per_day`). `hashtag_count` is deliberately NOT a
      rung: no production path reads it (the tags that reach a post come from
      `ContentStrategy::HashtagEngine` + `Personas::HashtagStrategy#max_tags`, which
      `PersonaEvolution#enforce_tag_baseline` pins to `TAG_BASELINE` after the 10 -> 30
      ramp was disproven), so ramping it was itself the silent no-op this requirement
      forbids — measured 2026-09-24: `posts_per_day` 3/3, `hashtag_count` 20 with zero
      consumers, 5 `escalate_cadence` decisions recorded, `strategy_exhausted` never once.
- [ ] 2.3 Resource-blocked attribution: count `comfyui_unclaimed`/`cadence_blocked` density
      over the review window and route to `resource_blocked`

## 3. Pivot + kill execution
- [ ] 3.1 Implement `Growth::Authority#mandate_pivot` — select + apply a structural lever,
      record `pivot_applied` with attributable identity
- [ ] 3.2 Extend `evaluate_previous_gates` to revert a failed pivot (`revert_pivot`)
- [ ] 3.3 Implement `goal_unattainable` halt: stop cadence production, surface to operator

## 4. Tests + validation
- [ ] 4.1 Spec `spec/services/growth/authority_spec.rb` for GO/BEHIND/PIVOT/KILL counters
- [x] 4.2 Spec `strategy_brain_spec.rb` for the `strategy_exhausted` persistence
      — `escalation exhaustion (live knobs only)`: at `posts_per_day 3/3` the review returns
      `strategy_exhausted`, writes the Decision naming `posts_per_day=3/3`, and leaves the
      inert `hashtag_count` untouched; plus the skip report's
      `next_strategy_review_at` (proven RED against the pre-change code: it returned
      `escalate_cadence` and `next_review_at`).
- [ ] 4.3 Spec `weekly_review_spec.rb` for `resource_blocked` + `goal_unattainable` verdicts
- [ ] 4.4 `openspec validate add-growth-authority --strict`