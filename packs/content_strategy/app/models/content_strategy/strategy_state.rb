# frozen_string_literal: true

module ContentStrategy
  class StrategyState < ApplicationRecord
    self.table_name = 'content_strategy_states'

    belongs_to :persona

    validates :persona, presence: true, uniqueness: true
    validates :active_strategy, presence: true
    validates :started_at, presence: true

    before_validation :set_defaults, on: :create

    def get_state(key)
      state_data[key.to_s]
    end

    def set_state(key, value)
      state_data[key.to_s] = value
      save!
    end

    def update_state(updates_hash)
      self.state_data = state_data.merge(updates_hash.stringify_keys)
      save!
    end

    def reset_state!
      self.state_data = {}
      self.started_at = Time.current
      save!
    end

    private

    def set_defaults
      self.active_strategy ||= 'thematic_rotation_strategy'
      self.started_at ||= Time.current
      self.strategy_config ||= {}
      self.state_data ||= {}
    end
  end
end
