class AddPersonaToRuns < ActiveRecord::Migration[8.0]
  def change
    add_reference :pipeline_runs, :persona, null: true, foreign_key: true
  end
end
