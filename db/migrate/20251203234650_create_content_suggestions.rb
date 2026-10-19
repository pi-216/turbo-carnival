class CreateContentSuggestions < ActiveRecord::Migration[8.0]
  def change
    create_table :content_suggestions do |t|
      t.references :gap_analysis, null: false, foreign_key: true
      t.references :content_pillar, null: false, foreign_key: true
      t.string :title
      t.text :description
      t.jsonb :prompt_data
      t.string :status
      t.datetime :used_at

      t.timestamps
    end
  end
end
