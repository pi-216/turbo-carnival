class CreateSchedulingPosts < ActiveRecord::Migration[8.0]
  def change
    create_table :scheduling_posts do |t|
      t.references :photo, null: false, foreign_key: true
      t.references :persona, null: false, foreign_key: true
      t.text :caption
      t.string :status, null: false, default: 'draft'
      t.string :provider_post_id
      t.datetime :scheduled_at
      t.datetime :posted_at

      t.timestamps
    end

    add_index :scheduling_posts, %i[photo_id persona_id], unique: true, name: 'index_posts_on_photo_id_and_persona_id'
  end
end
