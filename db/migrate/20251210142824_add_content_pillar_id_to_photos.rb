class AddContentPillarIdToPhotos < ActiveRecord::Migration[8.0]
  def change
    add_column :photos, :content_pillar_id, :bigint
    add_index :photos, :content_pillar_id
    add_foreign_key :photos, :content_pillars, column: :content_pillar_id
  end
end
