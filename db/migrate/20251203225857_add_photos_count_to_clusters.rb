class AddPhotosCountToClusters < ActiveRecord::Migration[8.0]
  def change
    add_column :clusters, :photos_count, :integer, default: 0, null: false
  end
end
