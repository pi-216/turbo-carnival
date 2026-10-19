class AddImageCandidateToPhotos < ActiveRecord::Migration[8.0]
  def change
    add_reference :photos, :image_candidate, null: true, foreign_key: true, index: { unique: true }
  end
end
