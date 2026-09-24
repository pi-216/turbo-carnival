class CreateGrowthTables < ActiveRecord::Migration[8.0]
  def change
    create_table :growth_goals do |t|
      t.bigint :persona_id, null: false
      t.string :instagram_handle
      t.integer :target_followers, default: 1000, null: false
      t.date :deadline
      t.integer :start_followers, default: 0, null: false
      t.integer :posts_per_day, default: 1, null: false
      t.integer :max_posts_per_day, default: 3, null: false
      t.integer :hashtag_count, default: 10, null: false
      t.integer :review_interval_days, default: 7, null: false
      t.datetime :last_reviewed_at
      t.string :status, default: 'active', null: false
      t.jsonb :strategy_config, default: {}, null: false
      t.timestamps
    end
    add_index :growth_goals, :persona_id
    add_index :growth_goals, :status

    create_table :growth_snapshots do |t|
      t.bigint :goal_id, null: false
      t.integer :followers, null: false
      t.datetime :taken_at, null: false
      t.timestamps
    end
    add_index :growth_snapshots, :goal_id
    add_index :growth_snapshots, :taken_at

    create_table :growth_decisions do |t|
      t.bigint :goal_id, null: false
      t.bigint :snapshot_id
      t.string :action, null: false
      t.string :reason
      t.jsonb :from_values, default: {}, null: false
      t.jsonb :to_values, default: {}, null: false
      t.datetime :decided_at, null: false
      t.timestamps
    end
    add_index :growth_decisions, :goal_id
    add_index :growth_decisions, :decided_at
  end
end
