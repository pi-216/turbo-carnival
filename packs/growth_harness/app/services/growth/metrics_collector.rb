# frozen_string_literal: true

module Growth
  # Capture follower-count snapshots from the connected Instagram account.
  class MetricsCollector
    attr_reader :goal

    def initialize(goal:)
      @goal = goal
    end

    # Fetch current followers and record a snapshot.
    # Returns the snapshot, or nil (with a recorded decision) if the API fails.
    def collect
      count = fetch_followers
      snapshot = goal.snapshots.create!(
        followers: count, taken_at: Time.current, **fetch_reach_attribution
      )
      update_start_followers(count)
      snapshot
    rescue Instagram::Client::Error, ArgumentError => e
      record_skip(e.message)
      nil
    end

    private

    def fetch_followers
      Instagram::Client.new.followers_count
    rescue ::Instagram::Client::Error => e
      raise e
    end

    # -> { follower_reach:, non_follower_reach:, reach_total:, profile_views: }
    # with any unanswered key omitted, so the column stays NULL (UNMEASURED) --
    # never 0, which would read as a measured "no discovery".
    #
    # Best effort BY DESIGN: the follower count is what Growth::Goal reads and
    # what every trajectory number is built from, so a failed or changed
    # insights call must never cost the snapshot. Failure is logged once, not
    # recorded as a Growth::Decision -- a decision row per failed call would
    # flood the review's signal with noise about a measurement, not about the
    # goal.
    def fetch_reach_attribution
      Instagram::Client.new.reach_attribution.to_h.compact
    rescue ::Instagram::Client::Error, ArgumentError, Faraday::Error => e
      Rails.logger.warn("Growth::MetricsCollector: reach attribution unavailable (#{e.message})")
      {}
    end

    def update_start_followers(count)
      return unless goal.snapshots.count == 1 && goal.start_followers.zero?

      goal.update!(start_followers: count)
    end

    def record_skip(error_message)
      Growth::Decision.create!(
        goal: goal,
        action: 'skip_data',
        reason: "Follower snapshot failed: #{error_message}",
        decided_at: Time.current
      )
      Rails.logger.warn("Growth::MetricsCollector: #{error_message}")
    end
  end
end