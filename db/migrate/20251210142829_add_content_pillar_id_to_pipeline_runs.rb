class AddContentPillarIdToPipelineRuns < ActiveRecord::Migration[8.0]
  def change
    add_column :pipeline_runs, :content_pillar_id, :bigint
    add_index :pipeline_runs, :content_pillar_id
    add_foreign_key :pipeline_runs, :content_pillars, column: :content_pillar_id
  end
end
