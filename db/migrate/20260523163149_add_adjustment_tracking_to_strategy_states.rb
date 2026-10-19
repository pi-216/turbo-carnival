class AddAdjustmentTrackingToStrategyStates < ActiveRecord::Migration[8.0]
  def change
    add_column :content_strategy_states, :last_adjustment, :jsonb, default: []
    add_column :content_strategy_states, :last_adjustment_at, :datetime
  end
end
