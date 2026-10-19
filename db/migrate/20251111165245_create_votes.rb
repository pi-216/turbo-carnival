class CreateVotes < ActiveRecord::Migration[8.0]
  def change
    create_table :votes do |t|
      t.integer :winner_id, null: false
      t.integer :loser_id, null: false

      t.timestamps
    end

    add_index :votes, [ :winner_id, :loser_id ], unique: true
    add_index :votes, :winner_id
    add_index :votes, :loser_id
    add_foreign_key :votes, :image_candidates, column: :winner_id
    add_foreign_key :votes, :image_candidates, column: :loser_id
  end
end
