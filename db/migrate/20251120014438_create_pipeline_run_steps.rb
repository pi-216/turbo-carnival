class CreatePipelineRunSteps < ActiveRecord::Migration[8.0]
  def change
    create_table :pipeline_run_steps do |t|
      t.references :pipeline_run, null: false, foreign_key: true
      t.references :pipeline_step, null: false, foreign_key: true
      t.boolean :approved, default: false, null: false
      t.datetime :approved_at
      t.integer :top_k_count, default: 3, null: false

      t.timestamps
    end

    add_index :pipeline_run_steps, [ :pipeline_run_id, :pipeline_step_id ], unique: true, name: 'index_pipeline_run_steps_on_run_and_step'

    # Backfill existing runs - auto-approve all steps
    reversible do |dir|
      dir.up do
        # Get max_children_per_node value (N)
        n_value = ENV.fetch('MAX_CHILDREN_PER_NODE', '3').to_i

        execute <<-SQL
          INSERT INTO pipeline_run_steps (pipeline_run_id, pipeline_step_id, approved, approved_at, top_k_count, created_at, updated_at)
          SELECT#{' '}
            pr.id as pipeline_run_id,
            ps.id as pipeline_step_id,
            true as approved,
            NOW() as approved_at,
            #{n_value} as top_k_count,
            NOW() as created_at,
            NOW() as updated_at
          FROM pipeline_runs pr
          CROSS JOIN pipeline_steps ps
          WHERE ps.pipeline_id = pr.pipeline_id
        SQL
      end
    end
  end
end
