class CreateClusters < ActiveRecord::Migration[8.0]
  def change
    create_table :clusters do |t|
      t.references :persona, null: false, foreign_key: true, index: true
      t.string :name, null: false
      t.integer :status, default: 0, null: false
      t.text :ai_prompt
      t.integer :photos_count, default: 0

      t.timestamps
    end

    add_index :clusters, [ :persona_id, :name ], unique: true
  end
end
