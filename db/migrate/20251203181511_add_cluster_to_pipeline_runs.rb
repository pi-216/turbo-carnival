class AddClusterToPipelineRuns < ActiveRecord::Migration[8.0]
  def change
    add_reference :pipeline_runs, :cluster, null: true, foreign_key: true, index: true
  end
end
