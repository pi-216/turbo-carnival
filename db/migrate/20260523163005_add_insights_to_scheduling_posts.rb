class AddInsightsToSchedulingPosts < ActiveRecord::Migration[8.0]
  def change
    add_column :scheduling_posts, :likes_count, :integer
    add_column :scheduling_posts, :comments_count, :integer
    add_column :scheduling_posts, :reach, :integer
    add_column :scheduling_posts, :saved_count, :integer
    add_column :scheduling_posts, :engagement_rate, :float
    add_column :scheduling_posts, :insights_updated_at, :datetime
  end
end
