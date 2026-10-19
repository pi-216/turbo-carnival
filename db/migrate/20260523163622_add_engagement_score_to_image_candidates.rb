class AddEngagementScoreToImageCandidates < ActiveRecord::Migration[8.0]
  def change
    add_column :image_candidates, :engagement_score, :float
  end
end
