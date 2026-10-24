# frozen_string_literal: true

# The render -> version edge, and the validation of the foreign keys added by
# `CreateContentConfigVersions` (#40).
#
# WHY THIS IS NOT IN THE MIGRATION THAT CREATED THE TABLES
# -------------------------------------------------------
# Two operations here are not transaction-safe, and strong_migrations refuses them inside one
# (correctly -- a 40-minute index build holding a write lock on `renders` would stall the
# publishing path):
#   * the index on `renders.content_config_version_id` must be built CONCURRENTLY, which
#     cannot run inside a transaction, so the migration declares `disable_ddl_transaction!`;
#   * validating a foreign key into `content_pillars` / `pipeline_steps` scans those tables,
#     which must not happen under the table-creating migration's lock.
#
# `renders.content_config_version_id` is NULLABLE on purpose: renders that predate the spine
# have UNKNOWN attribution, and a default version would be an invented fact.
class LinkRendersToContentConfigVersions < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    add_column :renders, :content_config_version_id, :bigint
    add_index :renders, :content_config_version_id, algorithm: :concurrently

    add_foreign_key :renders, :content_config_versions, validate: false
    validate_foreign_key :renders, :content_config_versions

    validate_foreign_key :content_config_versions, :content_pillars
    validate_foreign_key :content_config_versions, :pipeline_steps
    validate_foreign_key :content_config_version_prompt_parts, :content_config_versions
    validate_foreign_key :content_config_version_loras, :content_config_versions
  end

  def down
    remove_foreign_key :renders, :content_config_versions
    remove_index :renders, :content_config_version_id, algorithm: :concurrently
    remove_column :renders, :content_config_version_id
  end
end
