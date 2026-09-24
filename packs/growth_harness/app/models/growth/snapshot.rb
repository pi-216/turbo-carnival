# frozen_string_literal: true

module Growth
  # Point-in-time follower count for a goal, plus -- since 2026-09-24 -- where
  # that period's reach came from.
  #
  # The attribution columns are what separate "our followers see every post" from
  # "strangers find us": `non_follower_reach` > 0 is discovery, and it is the
  # number the pre-registered gate's distribution/reach pivot turns on. NULL
  # means the measurement was not collected; 0 means a measured zero, and only 0
  # supports a "no discovery" claim.
  class Snapshot < ApplicationRecord
    self.table_name = 'growth_snapshots'

    belongs_to :goal, class_name: 'Growth::Goal'

    validates :followers, presence: true, numericality: { greater_than_or_equal_to: 0 }
    validates :taken_at, presence: true

    # Measured non-follower reach on this snapshot. nil (unmeasured) is NOT a
    # negative -- see the class note.
    def discovery?
      !non_follower_reach.nil? && non_follower_reach.to_i.positive?
    end
  end
end
