class AddDefaultStatusToContentSuggestions < ActiveRecord::Migration[8.0]
  def change
    change_column_default :content_suggestions, :status, from: nil, to: 'pending'
  end
end
