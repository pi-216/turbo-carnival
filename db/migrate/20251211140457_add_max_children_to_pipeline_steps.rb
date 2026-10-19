class AddMaxChildrenToPipelineSteps < ActiveRecord::Migration[8.0]
  def change
    add_column :pipeline_steps, :max_children, :integer, default: 3, null: false

    # Backfill existing steps with default value
    reversible do |dir|
      dir.up do
        execute "UPDATE pipeline_steps SET max_children = 3 WHERE max_children IS NULL"
      end
    end
  end
end
