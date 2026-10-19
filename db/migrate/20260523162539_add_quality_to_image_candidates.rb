class AddQualityToImageCandidates < ActiveRecord::Migration[8.0]
  def change
    add_column :image_candidates, :quality_score, :float
    add_column :image_candidates, :quality_metrics, :jsonb
  end
end
