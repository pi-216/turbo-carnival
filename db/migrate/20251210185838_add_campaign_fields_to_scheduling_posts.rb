class AddCampaignFieldsToSchedulingPosts < ActiveRecord::Migration[8.0]
  def change
    # Make photo_id nullable to support "image promises"
    change_column_null :scheduling_posts, :photo_id, true

    # Add references to track image generation
    add_reference :scheduling_posts, :content_suggestion, foreign_key: true, index: true
    add_reference :scheduling_posts, :pipeline_run, foreign_key: true, index: true

    # Index for finding posts awaiting images
    add_index :scheduling_posts, :photo_id, where: "photo_id IS NULL", name: "index_scheduling_posts_on_missing_photo"
  end
end
