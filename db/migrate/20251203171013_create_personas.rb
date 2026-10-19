class CreatePersonas < ActiveRecord::Migration[8.0]
  def change
    create_table :personas do |t|
      t.string :name, null: false
      t.jsonb :caption_config, default: {}
      t.jsonb :hashtag_strategy, default: {}

      t.timestamps
    end

    add_index :personas, :name, unique: true
  end
end
