class CreateContentStrategyStates < ActiveRecord::Migration[8.0]
  def change
    create_table :content_strategy_states do |t|
      t.references :persona, null: false, foreign_key: true, index: { unique: true }
      t.string :active_strategy, null: false, default: 'thematic_rotation_strategy'
      t.jsonb :strategy_config, null: false, default: {}
      t.jsonb :state_data, null: false, default: {}
      t.datetime :started_at, null: false

      t.timestamps
    end
  end
end
