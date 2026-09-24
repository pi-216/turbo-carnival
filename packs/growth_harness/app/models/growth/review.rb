# frozen_string_literal: true

module Growth
  # A weekly full-picture review: follower trajectory + per-pillar engagement +
  # persona evolution. The record it leaves doubles as the audit log for the
  # autonomous persona experiment — every structural change is recorded in
  # applied_changes so it is reversible.
  class Review < ApplicationRecord
    self.table_name = 'growth_reviews'

    belongs_to :goal, class_name: 'Growth::Goal'

    validates :reviewed_at, presence: true
    validates :verdict, presence: true

    VERDICTS = %w[on_track behind ahead need_data flat declining resource_blocked goal_unattainable].freeze

    def on_track?
      verdict == 'on_track'
    end

    def pillars
      pillar_engagement || {}
    end
  end
end
