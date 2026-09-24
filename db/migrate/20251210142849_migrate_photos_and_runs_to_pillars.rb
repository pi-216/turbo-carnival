class MigratePhotosAndRunsToPillars < ActiveRecord::Migration[8.0]
  def up
    # Migrate photos from clusters to pillars
    execute <<-SQL
      UPDATE photos
      SET content_pillar_id = (
        SELECT COALESCE(
          (SELECT pillar_id FROM pillar_cluster_assignments#{' '}
           WHERE cluster_id = photos.cluster_id AND "primary" = true#{' '}
           LIMIT 1),
          (SELECT pillar_id FROM pillar_cluster_assignments#{' '}
           WHERE cluster_id = photos.cluster_id#{' '}
           LIMIT 1)
        )
      )
      WHERE cluster_id IS NOT NULL
    SQL

    # Migrate pipeline runs from clusters to pillars
    execute <<-SQL
      UPDATE pipeline_runs
      SET content_pillar_id = (
        SELECT COALESCE(
          (SELECT pillar_id FROM pillar_cluster_assignments#{' '}
           WHERE cluster_id = pipeline_runs.cluster_id AND "primary" = true#{' '}
           LIMIT 1),
          (SELECT pillar_id FROM pillar_cluster_assignments#{' '}
           WHERE cluster_id = pipeline_runs.cluster_id#{' '}
           LIMIT 1)
        )
      )
      WHERE cluster_id IS NOT NULL
    SQL

    # Verify all photos got migrated
    unmigrated_photos = execute("SELECT COUNT(*) FROM photos WHERE cluster_id IS NOT NULL AND content_pillar_id IS NULL").first['count'].to_i
    if unmigrated_photos > 0
      raise "Migration failed: #{unmigrated_photos} photos could not be assigned to pillars"
    end

    # Runs without cluster_id stay NULL (historical data)
    say "Migration complete:"
    migrated_photos = execute("SELECT COUNT(*) FROM photos WHERE content_pillar_id IS NOT NULL").first['count']
    migrated_runs = execute("SELECT COUNT(*) FROM pipeline_runs WHERE content_pillar_id IS NOT NULL").first['count']
    say "  - #{migrated_photos} photos migrated to pillars"
    say "  - #{migrated_runs} pipeline runs migrated to pillars"
  end

  def down
    execute "UPDATE photos SET content_pillar_id = NULL"
    execute "UPDATE pipeline_runs SET content_pillar_id = NULL"
  end
end
