# frozen_string_literal: true

module ContentStrategy
  module TimingOptimization
    def get_optimal_posting_time(photo:)
      config = context.config
      last_post_time = last_posted_time

      # Calculate minimum next allowed time
      min_next_time = if last_post_time
        last_post_time + config.posting_days_gap.days
      else
        Time.current
      end

      # Try to find time in optimal window
      optimal_time = next_time_in_window(
        after: min_next_time,
        start_hour: config.optimal_time_start_hour,
        end_hour: config.optimal_time_end_hour
      )

      # If optimal window is too soon, try alternative window
      if optimal_time < min_next_time
        optimal_time = next_time_in_window(
          after: min_next_time,
          start_hour: config.alternative_time_start_hour,
          end_hour: config.alternative_time_end_hour
        )
      end

      optimal_time
    end

    private

    def last_posted_time
      # Check both posted history AND future scheduled posts
      last_history_time = context.history.first&.created_at

      last_scheduled_time = Scheduling::Post
        .where(persona: context.persona, status: [ 'scheduled', 'draft' ])
        .where('scheduled_at > ?', Time.current)
        .maximum(:scheduled_at)

      # Return whichever is later
      [ last_history_time, last_scheduled_time ].compact.max
    end

    def next_time_in_window(after:, start_hour:, end_hour:)
      # Start from the day after 'after'
      candidate_day = after.to_date + 1.day

      # Build datetime in the optimal window
      start_time = candidate_day.to_time + start_hour.hours

      # If start_time is before 'after', move to next day
      while start_time < after
        candidate_day += 1.day
        start_time = candidate_day.to_time + start_hour.hours
      end

      start_time
    end
  end
end
