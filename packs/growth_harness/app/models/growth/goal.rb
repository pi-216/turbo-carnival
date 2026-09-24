# frozen_string_literal: true

module Growth
  # A growth goal for one persona: how many followers by when.
  class Goal < ApplicationRecord
    self.table_name = 'growth_goals'

    belongs_to :persona
    has_many :snapshots, class_name: 'Growth::Snapshot', dependent: :destroy
    has_many :decisions, class_name: 'Growth::Decision', dependent: :destroy
    has_many :reviews, class_name: 'Growth::Review', dependent: :destroy

    validates :persona_id, presence: true
    validates :target_followers, presence: true, numericality: { greater_than: 0 }
    validates :status, inclusion: { in: %w[active paused] }

    scope :active, -> { where(status: 'active') }
    scope :for_persona, ->(persona) { where(persona: persona) }

    before_create :set_default_deadline

    def latest_followers
      latest_snapshot&.followers || start_followers
    end

    def latest_snapshot
      snapshots.order(taken_at: :desc).first
    end

    def followers_gained
      latest_followers - start_followers
    end

    def days_elapsed
      [ (Date.current - created_at.to_date).to_i, 0 ].max
    end

    def days_remaining
      [ (deadline - Date.current).to_i, 0 ].max
    end

    # Linear trajectory: required daily follower growth to hit target on time.
    def required_daily_growth
      remaining = target_followers - latest_followers
      return 0.0 if remaining <= 0 || days_remaining <= 0

      remaining.to_f / days_remaining
    end

    def effective_posts_per_day
      [ posts_per_day, max_posts_per_day ].min
    end

    # Projected completion date at the current measured pace (nil if flat).
    def projected_completion_date
      pace = average_daily_growth
      return nil unless pace && pace.positive?

      remaining = target_followers - latest_followers
      return Date.current if remaining <= 0

      Date.current + (remaining.to_f / pace).ceil
    end

    def on_track?
      return true if traj_ratio.nil?

      traj_ratio >= 1.0
    end

    # measured / required — >=1 means at or ahead of the goal trajectory
    def traj_ratio
      required = required_daily_growth
      measured = average_daily_growth
      return nil if required.zero? || measured.nil?

      measured / required
    end

    # Average daily follower growth over the snapshots we have (nil if <2 snapshots).
    def average_daily_growth
      return nil if snapshots.count < 2

      oldest = snapshots.order(taken_at: :asc).first
      newest = latest_snapshot
      days = ((newest.taken_at - oldest.taken_at) / 1.day).to_f
      return nil if days <= 0

      (newest.followers - oldest.followers).to_f / days
    end

    private

    def set_default_deadline
      self.deadline ||= (created_at || Date.current).to_date + 365.days
    end
  end
end
