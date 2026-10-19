class AddEngagementToStrategyStates < ActiveRecord::Migration[8.0]
  def change
    add_column :content_strategy_states, :pillar_engagement_scores, :jsonb, default: {}
    add_column :content_strategy_states, :selection_history, :jsonb, default: []
  end
end
