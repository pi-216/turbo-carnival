class AddQualityMetricsToPipelineRuns < ActiveRecord::Migration[8.0]
  def change
    add_column :pipeline_runs, :quality_metrics, :jsonb, default: {}
    add_column :pipeline_runs, :reject_reason, :text
  end
end