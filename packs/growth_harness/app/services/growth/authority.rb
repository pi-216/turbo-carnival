# frozen_string_literal: true

module Growth
  # Decision-authority layer: pre-registered, falsifiable verdicts that MANDATE a
  # change when the trajectory is persistently off-track. Thresholds are named
  # constants; the weekly review is the ruling body. This turns the advisory loop
  # (measure → log → repeat) into a gated loop (measure → verdict → MANDATED action).
  #
  # Two failure modes the old StrategyBrain could not express:
  #   1. RESOURCE_BLOCKED — the render GPU is walled off (comfyui_unclaimed /
  #      cadence_blocked density), so "behind" is a resource problem, not strategy.
  #   2. GOAL_UNATTAINABLE — the goal's required daily growth diverges from measured
  #      (catch-up treadmill), so no volume knob can close a >= 5x gap.
  class Authority
    GO_RATIO                = 1.0   # >= -> on track
    BEHIND_RATIO            = 0.5   # [0.5, 1.0) -> behind (escalate volume)
    PIVOT_RATIO             = 0.5   # < -> mandate structural pivot
    KILL_RATIO              = 0.2   # < -> goal unattainable (halt + re-target)
    PIVOT_AFTER_REVIEWS     = 2     # consecutive reviews below PIVOT_RATIO
    KILL_AFTER_REVIEWS      = 4     # consecutive reviews below KILL_RATIO
    FAILED_PIVOTS_FOR_KILL  = 2
    RESOURCE_BLOCK_RATIO    = 0.6   # fraction of window hours with render blocked

    # Verdicts that halt strategy tuning: the strategy is broken (net loss), the
    # render resource is walled off, or the goal is mathematically unattainable.
    TERMINAL_VERDICTS = %w[declining resource_blocked goal_unattainable].freeze

    def initialize(goal:)
      @goal = goal
    end

    # True when render-blockage decisions (comfyui_unclaimed / cadence_blocked)
    # cover at least RESOURCE_BLOCK_RATIO of the review window's hours. A
    # walled-off GPU is a resource problem: escalating cadence/persona against it
    # is noise, and the fix is to reclaim the scheduler resource.
    def resource_blocked?
      window_hours = @goal.review_interval_days.to_i * 24
      return false if window_hours <= 0

      blocked = @goal.decisions
                     .where(decided_at: window_hours.hours.ago..)
                     .where(action: %w[comfyui_unclaimed cadence_blocked])
                     .count

      (blocked.to_f / window_hours) >= RESOURCE_BLOCK_RATIO
    end

    # True when the measured pace is below the KILL threshold and that behind
    # state has persisted for KILL_AFTER_REVIEWS consecutive weekly reviews. The
    # catch-up treadmill makes this worse over time: required_daily_growth rises
    # as the deadline window shrinks, so a gap that is merely "behind" is
    # structurally unattainable. Only judged when the render resource is NOT
    # blocked (the weekly review sequences resource_blocked first).
    def goal_unattainable?
      ratio = @goal.traj_ratio
      return false if ratio.nil? || ratio >= KILL_RATIO

      behind_run = @goal.reviews
                        .where(verdict: %w[behind goal_unattainable])
                        .order(reviewed_at: :desc)
                        .limit(KILL_AFTER_REVIEWS)
      behind_run.count >= KILL_AFTER_REVIEWS
    end
  end
end
