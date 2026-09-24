class CreateContentPillars < ActiveRecord::Migration[8.0]
  def change
    create_table :content_pillars do |t|
      t.references :persona, null: false, foreign_key: true, index: true
      t.string :name, null: false
      t.text :description
      t.decimal :weight, precision: 5, scale: 2, default: 0.0, null: false
      t.boolean :active, default: true, null: false
      t.date :start_date
      t.date :end_date
      t.jsonb :guidelines, default: {}
      t.integer :target_posts_per_week
      t.integer :priority, default: 3, null: false

      t.timestamps
    end

    add_index :content_pillars, [ :persona_id, :name ], unique: true
    add_index :content_pillars, :active

    add_check_constraint :content_pillars, "weight >= 0 AND weight <= 100", name: "weight_range_check"
    add_check_constraint :content_pillars, "end_date IS NULL OR start_date IS NULL OR end_date > start_date", name: "date_range_check"
    add_check_constraint :content_pillars, "priority >= 1 AND priority <= 5", name: "priority_range_check"
  end
end
