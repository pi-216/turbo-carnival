class EnhanceSchedulingPosts < ActiveRecord::Migration[8.0]
  def change
    add_column :scheduling_posts, :cluster_id, :bigint
    add_column :scheduling_posts, :strategy_name, :string
    add_column :scheduling_posts, :optimal_time_calculated, :datetime
    add_column :scheduling_posts, :hashtags, :jsonb, default: []
    add_column :scheduling_posts, :caption_metadata, :jsonb

    add_index :scheduling_posts, :cluster_id
    add_index :scheduling_posts, :strategy_name
    add_foreign_key :scheduling_posts, :clusters
  end
end
