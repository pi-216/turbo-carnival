class CreateGrowthReviews < ActiveRecord::Migration[8.0]
  def change
    create_table :growth_reviews do |t|
      t.bigint :goal_id, null: false
      t.datetime :reviewed_at, null: false
      t.integer :followers, default: 0
      t.integer :followers_delta
      t.decimal :required_daily, precision: 8, scale: 2
      t.decimal :measured_daily, precision: 8, scale: 2
      t.decimal :trajectory_ratio, precision: 6, scale: 3
      t.string :verdict, null: false            # on_track / behind / ahead / need_data / flat
      t.jsonb :pillar_engagement, default: {}   # { pillar_name => {posts, avg_engagement, saved, follows} }
      t.jsonb :top_pillars, default: []         # ordered strongest→weakest
      t.string :persona_direction                # narrative read on persona evolution
      t.jsonb :recommendations, default: []      # list of suggested experiments
      t.jsonb :applied_changes, default: []      # record of every mutation (bounded, reversible)
      t.timestamps
    end
    add_index :growth_reviews, :goal_id
    add_index :growth_reviews, :reviewed_at
  end
end
