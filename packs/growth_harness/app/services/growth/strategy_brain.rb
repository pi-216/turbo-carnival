# frozen_string_literal: true

module Growth
  # Periodic review: measure growth vs. the goal trajectory and adjust strategy.
  #
  # Decision rules (recorded in Growth::Decision for auditability):
  # - ratio < 0            → BREAK: followers are leaving (negative measured
  #                          growth). Escalating output is contraindicated —
  #                          retract cadence, flag that the strategy is broken.
  # - ratio < 0.75          → escalate: raise posts_per_day (up to max), then hashtags
  # - ratio > 1.5           → cut back cadence to conserve photo inventory
  # - < 2 snapshots         → defer, noting we need data
  # - interval not elapsed  → skip, report next due date (EXCEPT when declining:
  #                          follower loss is an anomaly and never waits out the interval)
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

    def escalate(ratio)
      from = { posts_per_day: goal.posts_per_day, hashtag_count: goal.hashtag_count }

      if goal.posts_per_day < goal.max_posts_per_day
        goal.update!(posts_per_day: goal.posts_per_day + 1, last_reviewed_at: Time.current)
      elsif goal.hashtag_count < 30
        goal.update!(hashtag_count: goal.hashtag_count + 5, last_reviewed_at: Time.current)
      else
        return exhaust(ratio)
      end

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

    # ESCALATION EXHAUSTED — all volume knobs are at max yet the trajectory is
    # still behind. Persist this as a Decision (the old code returned a transient
    # hash and wrote nothing — silence masquerading as "hold"). This is the
    # authority's signal that volume cannot fix the gap; the weekly review's
    # resource_blocked / goal_unattainable verdicts take it from here.
    def exhaust(ratio)
      from = { posts_per_day: goal.posts_per_day, hashtag_count: goal.hashtag_count }
      goal.touch(:last_reviewed_at)
      Growth::Decision.create!(
        goal: goal,
        snapshot: goal.latest_snapshot,
        action: 'strategy_exhausted',
        reason: "at max effort (posts_per_day=#{goal.posts_per_day}/#{goal.max_posts_per_day}, " \
                "hashtag_count=#{goal.hashtag_count}/30) yet ratio #{ratio.round(3)} — " \
                'no volume knob left; fix the render resource or re-target the goal',
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

    def skip_report
      { view: 'skip', next_review_at: (goal.last_reviewed_at || Time.current) + goal.review_interval_days.days }
    end
  end
end