class UpdatePillarClusterAssignmentsAddClusterFk < ActiveRecord::Migration[8.0]
  def change
    add_foreign_key :pillar_cluster_assignments, :clusters, column: :cluster_id, on_delete: :cascade
    add_index :pillar_cluster_assignments, :cluster_id
  end
end
