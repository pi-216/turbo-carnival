# frozen_string_literal: true

module Growth
  # Allocate a DISTINCT future publish slot for a newly produced post.
  #
  # WHY THIS EXISTS
  # Every producer in this pack used to place a post at
  # `Time.current + offset_days.days`, so a post's wall-clock time was whatever
  # time of day the producing tick happened to run. Posts created by different
  # ticks for the same target day therefore landed on the same publishing hour,
  # and the hourly publisher (bin/scheduled_posting.sh, user crontab) released
  # them all in a single tick. Measured 2026-09-19:
  #
  #   posts 317 / 319 / 326 published 06:00:14Z / 06:00:26Z / 06:00:38Z
  #   (three posts inside 24 seconds), and 2026-09-20 carried 6 future posts
  #   against a 3/day cadence cap.
  #
  # The repo already had the right convention -- PostAutomation::CreateScheduledPost
  # #calculate_next_slot spaces posts inside a posting window -- the growth
  # producers simply bypassed it.
  #
  # RULE: pick the earliest day at or after the minimum lead whose future post
  # count is still below posts_per_day, then the earliest window slot on that day
  # that is free and at least SLOT_GAP_MINUTES from every slot already taken.
  # Two posts can therefore never share a publisher tick, and no day can exceed
  # the cadence cap.
  class PostSlotPlanner
    # Posting windows in Time.zone (this app runs UTC) -- the same windows the
    # strategy/command path uses. Spacing inside them is what prevents the burst.
    WINDOWS = [[9, 12], [14, 17]].freeze
    SLOT_GAP_MINUTES = 90
    MIN_LEAD_DAYS = 1
    # Bounded search: with a 7-day lookahead and a few posts/day the first few
    # days always have room; the bound only exists so a pathological queue can
    # never spin this method forever.
    MAX_DAYS_AHEAD = 60

    def self.next_slot(persona:, posts_per_day:, min_lead_days: MIN_LEAD_DAYS, now: Time.current)
      new(persona: persona, posts_per_day: posts_per_day,
          min_lead_days: min_lead_days, now: now).next_slot
    end

    def initialize(persona:, posts_per_day:, min_lead_days: MIN_LEAD_DAYS, now: Time.current)
      @persona = persona
      @posts_per_day = [posts_per_day.to_i, 1].max
      @min_lead_days = [min_lead_days.to_i, 1].max
      @now = now
    end

    def next_slot
      first_day = (@now + @min_lead_days.days).to_date

      (0...MAX_DAYS_AHEAD).each do |i|
        slots = free_slots(first_day + i)
        return slots.first if slots.any?
      end

      # Never block a producer on slot math: place it after the last known slot so
      # it still cannot collide with one.
      (taken.max || @now) + SLOT_GAP_MINUTES.minutes
    end

    private

    # Future draft/scheduled posts for this persona -- the same population the
    # publisher selects from, so the plan is measured against what will actually
    # be released.
    def taken
      @taken ||= Scheduling::Post
                 .where(persona: @persona, status: %w[draft scheduled])
                 .where('scheduled_at > ?', @now)
                 .pluck(:scheduled_at)
                 .sort
    end

    def free_slots(day)
      used = taken.select { |t| t.to_date == day }
      return [] if used.size >= @posts_per_day

      window_slots(day).reject do |slot|
        slot < @now || used.any? { |u| (u - slot).abs < SLOT_GAP_MINUTES.minutes }
      end
    end

    def window_slots(day)
      WINDOWS.flat_map do |(from_hour, to_hour)|
        out = []
        slot = Time.zone.local(day.year, day.month, day.day, from_hour, 0)
        while slot.hour < to_hour
          out << slot
          slot += SLOT_GAP_MINUTES.minutes
        end
        out
      end
    end
  end
end
