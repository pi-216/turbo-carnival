# frozen_string_literal: true

module Growth
  # Periodic review: measure growth vs. the goal trajectory and adjust strategy.
  #
  # Decision rules (recorded in Growth::Decision for auditability):
  # - ratio < 0            → BREAK: followers are leaving (negative measured
  #                          growth). Escalating output is contraindicated —
  #                          retract cadence, flag that the strategy is broken.
  # - ratio < 0.75          → escalate: raise posts_per_day (up to max); at max,
  #                          persist `strategy_exhausted` (the ladder has no live
  #                          knob left -- see escalate)
  # - ratio > 1.5           → cut back cadence to conserve photo inventory
  # - < 2 snapshots         → defer, noting we need data
  # - interval not elapsed  → skip, reporting next_strategy_review_at (the BRAIN's
  #                          own next adjustment, which is NOT the weekly review's
  #                          cadence -- see skip_report; EXCEPT when declining:
  #                          follower loss is an anomaly and never waits it out)
  class StrategyBrain
    ESCALATE_THRESHOLD = 0.75
    CUTBACK_THRESHOLD  = 1.5
    DECLINE_RATIO      = 0.0   # measured growth negative = audience shrinking

    attr_reader :goal

    def initialize(goal:)
      @goal = goal
    end

    def review(force: false)
      return skip_report unless force || review_due?

      ratio = goal.traj_ratio

      if ratio.nil?
        return { status: 'need_data', snapshot_count: goal.snapshots.count }
      end

      decide(ratio)
    end

    private

    def decide(ratio)
      if ratio < DECLINE_RATIO
        break_state(ratio)
      elsif ratio < ESCALATE_THRESHOLD
        escalate(ratio)
      elsif ratio > CUTBACK_THRESHOLD
        cut_back(ratio)
      else
        hold(ratio)
      end
    end

    # CONCLUSION STATE — not just "behind". Measured growth is NEGATIVE: people
    # are unfollowing. Pushing more content at a shrinking audience is the wrong
    # move, so retract cadence toward minimum and log the conclusion loudly so
    # the operator / weekly reviewer can see the strategy is broken, not slow.
    def break_state(ratio)
      from = { posts_per_day: goal.posts_per_day, hashtag_count: goal.hashtag_count }

      if goal.posts_per_day > 1
        goal.update!(posts_per_day: goal.posts_per_day - 1, last_reviewed_at: Time.current)
      else
        goal.touch(:last_reviewed_at)
      end

      log_decision(
        :negative_growth_break,
        from,
        "followers are LEAVING (measured #{goal.average_daily_growth&.round(3)}/day, " \
        "ratio #{ratio.round(3)}) — strategy broken, not behind; escalated output " \
        "contraindicated, cadence retracted; halt scaling until root cause diagnosed " \
        '(content quality, gates, audience fit)'
      )
    end

    # ESCALATION LADDER — live knobs only. `goal.hashtag_count` used to be the
    # second rung and NOTHING in the production path reads it: the tags that
    # reach a post come from ContentStrategy::HashtagEngine over the pillar +
    # persona strategy (config/content_strategy.yml hashtag_count_min/max) and
    # from Personas::HashtagStrategy#max_tags, which PersonaEvolution#enforce_tag_baseline
    # pins to TAG_BASELINE because the 10 -> 30 "broaden tags" ramp was DISPROVEN
    # (reviews 2-5, engagement flat under it). Ramping an unread field made the
    # ladder's top rung a SILENT NO-OP -- exactly what the escalation-exhaustion
    # requirement ("escalation reaching its ceiling SHALL NOT be a silent no-op")
    # exists to prevent -- and it POSTPONED the `strategy_exhausted` conclusion
    # past the point where the last live knob had been spent. Measured
    # 2026-09-24: posts_per_day 3/3, hashtag_count 20 with zero consumers,
    # 5 escalate_cadence decisions recorded, strategy_exhausted never once.
    def escalate(ratio)
      from = { posts_per_day: goal.posts_per_day, hashtag_count: goal.hashtag_count }
      return exhaust(ratio) unless goal.posts_per_day < goal.max_posts_per_day

      goal.update!(posts_per_day: goal.posts_per_day + 1, last_reviewed_at: Time.current)
      log_decision(:escalate_cadence, from, reason_text(ratio, ahead: false))
    end

    def cut_back(ratio)
      return hold_declared(ratio, 'already minimal') if goal.posts_per_day <= 1

      from = { posts_per_day: goal.posts_per_day, hashtag_count: goal.hashtag_count }
      goal.update!(posts_per_day: goal.posts_per_day - 1, last_reviewed_at: Time.current)
      log_decision(:reduce_cadence, from, reason_text(ratio, ahead: true))
    end

    def hold(ratio)
      goal.touch(:last_reviewed_at)
      { view: 'hold', ratio: ratio.round(2), note: 'on trajectory' }
    end

    def hold_declared(ratio, note)
      goal.touch(:last_reviewed_at)
      { view: 'hold', ratio: ratio.round(2), note: note }
    end

    # ESCALATION EXHAUSTED — every LIVE volume knob is at max yet the trajectory
    # is still behind. Persist this as a Decision (the old code returned a
    # transient hash and wrote nothing — silence masquerading as "hold"). This is
    # the authority's signal that volume cannot fix the gap; the weekly review's
    # resource_blocked / goal_unattainable verdicts take it from here.
    #
    # The reason names `posts_per_day` ONLY: it is the ladder's last live knob
    # (see escalate), so naming `hashtag_count` here would report a ceiling on a
    # field no consumer reads — the same unbound signal, moved into the audit
    # trail.
    def exhaust(ratio)
      from = { posts_per_day: goal.posts_per_day, hashtag_count: goal.hashtag_count }
      goal.touch(:last_reviewed_at)
      Growth::Decision.create!(
        goal: goal,
        snapshot: goal.latest_snapshot,
        action: 'strategy_exhausted',
        reason: "at max effort (posts_per_day=#{goal.posts_per_day}/#{goal.max_posts_per_day}) " \
                "yet ratio #{ratio.round(3)} — no volume knob left; fix the render resource " \
                'or re-target the goal',
        from_values: from,
        to_values: from,
        decided_at: Time.current
      )
      { view: 'strategy_exhausted', ratio: ratio.round(2), to: from }
    end

    def log_decision(action, from, reason)
      Growth::Decision.create!(
        goal: goal,
        snapshot: goal.latest_snapshot,
        action: action.to_s,
        reason: reason,
        from_values: from,
        to_values: to_values_hash,
        decided_at: Time.current
      )
      { view: action.to_s, ratio: goal.traj_ratio&.round(2), to: to_values_hash }
    end

    def reason_text(ratio, ahead: false)
      direction = ahead ? 'ahead of' : 'behind'
      "measured/required ratio #{ratio.round(3)} (#{direction} trajectory); adjusted cadence"
    end

    def to_values_hash
      { posts_per_day: goal.posts_per_day, hashtag_count: goal.hashtag_count }
    end

    def review_due?
      return true if goal.last_reviewed_at.nil?
      # Follower loss is an ANOMALY: fire the break conclusion on the first
      # negative-growth tick, but do NOT spam it hourly — re-confirm on the
      # review-interval cadence (the weekly review judges ongoing decline).
      return true if declining? && no_recent_break_conclusion?

      goal.last_reviewed_at < goal.review_interval_days.days.ago
    end

    def declining?
      measured = goal.average_daily_growth
      !measured.nil? && measured.negative?
    end

    # True when no negative_growth_break conclusion was recorded within the
    # current review window — i.e. this decline episode hasn't been concluded yet.
    def no_recent_break_conclusion?
      latest = goal.decisions.order(decided_at: :desc).find_by(action: 'negative_growth_break')
      latest.nil? || latest.decided_at < goal.review_interval_days.days.ago
    end

    # The BRAIN's OWN throttle -- NOT the weekly review's cadence. Two different
    # clocks both read as "the next review", and this key is the one a reader
    # would mistake for the pre-registered one:
    #   * here       -- `goal.last_reviewed_at` (touched on every DUE evaluation,
    #                   including a no-op hold) + review_interval_days = when the
    #                   strategy brain may adjust again. Lands on whatever weekday
    #                   the last adjustment happened to fall on.
    #   * the gate's -- `growth_reviews.reviewed_at` + review_interval_days = when
    #                   the weekly review -- the pre-registered GO/PIVOT/KILL read
    #                   -- runs (Mondays 13:00Z here).
    # Measured 2026-09-24 they disagreed by 2 days (this clock said 09-30 while
    # the registered read was 09-28), and the hourly brain report carried the
    # wrong one. Named for what it is so no reader sizes a read off it; the ops
    # board's `check_weekly_review_due` watches the gate's own clock.
    def skip_report
      { view: 'skip',
        next_strategy_review_at: (goal.last_reviewed_at || Time.current) + goal.review_interval_days.days }
    end
  end
end
