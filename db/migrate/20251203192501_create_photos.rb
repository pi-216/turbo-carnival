class CreatePhotos < ActiveRecord::Migration[8.0]
  def change
    create_table :photos do |t|
      t.references :persona, null: false, foreign_key: true, index: true
      t.references :cluster, null: true, foreign_key: true, index: true
      t.string :path, null: false

      t.timestamps
    end

    add_index :photos, :path, unique: true
  end
end
