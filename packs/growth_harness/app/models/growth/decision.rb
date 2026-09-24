# frozen_string_literal: true

module Growth
  # Audit record of every strategy change the harness makes (or declines to make).
  class Decision < ApplicationRecord
    self.table_name = 'growth_decisions'

    belongs_to :goal, class_name: 'Growth::Goal'
    belongs_to :snapshot, class_name: 'Growth::Snapshot', optional: true

    validates :action, presence: true
    validates :decided_at, presence: true

    ACTIONS = %w[escalate_cadence reduce_cadence adjust_hashtags
                 strategy_rotation take_snapshot skip_data cadence_blocked
                 strategy_exhausted pivot_applied revert_pivot].freeze

    def to_h
      {
        action: action,
        reason: reason,
        from: from_values,
        to: to_values,
        decided_at: decided_at
      }
    end
  end
end
