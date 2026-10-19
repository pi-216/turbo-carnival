class CreateGapAnalyses < ActiveRecord::Migration[8.0]
  def change
    create_table :gap_analyses do |t|
      t.references :persona, null: false, foreign_key: true
      t.datetime :analyzed_at
      t.jsonb :coverage_data
      t.jsonb :recommendations

      t.timestamps
    end
  end
end
