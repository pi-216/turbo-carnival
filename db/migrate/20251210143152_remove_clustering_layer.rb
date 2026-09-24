class RemoveClusteringLayer < ActiveRecord::Migration[8.0]
  def up
    # Remove foreign keys from all tables that reference clusters
    remove_foreign_key :photos, :clusters if foreign_key_exists?(:photos, :clusters)
    remove_foreign_key :pipeline_runs, :clusters if foreign_key_exists?(:pipeline_runs, :clusters)
    remove_foreign_key :scheduling_posts, :clusters if foreign_key_exists?(:scheduling_posts, :clusters)
    remove_foreign_key :content_strategy_histories, :clusters if foreign_key_exists?(:content_strategy_histories, :clusters)

    # Remove cluster_id columns from all tables
    remove_column :photos, :cluster_id if column_exists?(:photos, :cluster_id)
    remove_column :pipeline_runs, :cluster_id if column_exists?(:pipeline_runs, :cluster_id)
    remove_column :scheduling_posts, :cluster_id if column_exists?(:scheduling_posts, :cluster_id)
    remove_column :content_strategy_histories, :cluster_id if column_exists?(:content_strategy_histories, :cluster_id)

    # Drop the join table
    drop_table :pillar_cluster_assignments if table_exists?(:pillar_cluster_assignments)

    # Drop the clusters table
    drop_table :clusters if table_exists?(:clusters)

    say "Clustering layer removed successfully"
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Cannot restore clustering layer - data has been migrated to pillars"
  end
end
