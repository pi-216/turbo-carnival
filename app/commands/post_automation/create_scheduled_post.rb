# frozen_string_literal: true

module PostAutomation
  # Step 3: Create a scheduled post record
  class CreateScheduledPost < GLCommand::Callable
    requires photo: ContentPillars::Photo, persona: Persona, caption: String
    allows optimal_time: Time, hashtags: Array, caption_metadata: Hash

    returns :post

    def call
      # Use strategy's optimal time or calculate next available slot
      scheduled_time = optimal_time || calculate_next_slot

      context.post = Scheduling::Post.create!(
        photo: photo,
        persona: persona,
        caption: caption,
        scheduled_at: scheduled_time,
        optimal_time_calculated: optimal_time || scheduled_time,
        status: "scheduled"
      )
    end

    def rollback
      context.post&.destroy
    end

    private

    def calculate_next_slot
      # Find the LATEST scheduled time for this persona
      max_scheduled_time = Scheduling::Post
        .where(persona: persona, status: [ "scheduled", "draft" ])
        .where("scheduled_at > ?", Time.current)
        .maximum(:scheduled_at)

      if max_scheduled_time
        # Space posts roughly 24 hours apart for daily cadence
        base_time = max_scheduled_time + rand(20..28).hours

        # Adjust to optimal posting window (9 AM - noon)
        adjust_to_optimal_window(base_time)
      else
        # No posts scheduled yet - schedule for tomorrow at 10 AM
        Time.current.tomorrow.change(hour: 10, min: rand(0..59))
      end
    end

    def adjust_to_optimal_window(time)
      hour = time.hour

      # If already in optimal window (9 AM - noon), use it
      return time if hour >= 9 && hour < 12

      # If in alternative window (2 PM - 5 PM), use it
      return time if hour >= 14 && hour < 17

      # Otherwise, move to next day's optimal window
      time.tomorrow.change(hour: rand(9..11), min: rand(0..59))
    end
  end
end
