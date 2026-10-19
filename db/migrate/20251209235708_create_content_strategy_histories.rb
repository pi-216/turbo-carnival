class CreateContentStrategyHistories < ActiveRecord::Migration[8.0]
  def change
    create_table :content_strategy_histories do |t|
      t.references :persona, null: false, foreign_key: true, index: true
      t.references :post, null: true, foreign_key: { to_table: :scheduling_posts }
      t.references :cluster, null: true, foreign_key: true, index: true
      t.string :strategy_name, null: false, index: true
      t.jsonb :decision_context, null: false, default: {}

      t.datetime :created_at, null: false, index: true
    end
  end
end
