class AddFieldsToClusters < ActiveRecord::Migration[8.0]
  def change
    add_reference :clusters, :persona, null: false, foreign_key: true, index: true
    add_column :clusters, :name, :string, null: false
    add_column :clusters, :ai_prompt, :text
    add_column :clusters, :status, :string, null: false, default: 'active'

    add_index :clusters, [ :persona_id, :name ], unique: true
  end
end
