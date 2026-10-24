# frozen_string_literal: true

# The content config as an immutable VERSION (#40, PRD 0002 / plan item W1.2).
#
# WHY THIS EXISTS
# ---------------
# A render's own columns say what ONE render executed. They cannot say which version of the
# CONFIG it ran under, because the config is not a thing in this database: it is spread
# across `content_pillars` rows (weight, wardrobe rung), the scene bank in
# `Growth::PillarPrompt`, and the graph in `pipeline_steps.comfy_workflow_json`. So "the
# config changed and reach moved" has no address, and two render sets cannot be compared
# without a human reconstructing which renders belonged to which change.
#
# WHAT IS DELIBERATELY *NOT* HERE
# -------------------------------
# * No seed, no asset, no timestamp. Those vary per RENDER, not per config -- one version
#   legitimately covers hundreds of renders. Pinning them here would make every render its
#   own version, which is the reverse of the point.
# * `photos.provenance` is untouched. It is the synthetic-mark COMPLIANCE ledger (legal
#   floor), and this PRD keeps a legal record out of an experiment record.
# * NOTHING IS BACKFILLED. Hundreds of renders exist with no recorded config; a guessed
#   version would silently poison every later comparison. Absent stays absent, which is why
#   `renders.content_config_version_id` is nullable and why nothing is defaulted.
# * `workflow_path` and `pipeline_step_id` are recorded but are NOT part of a version's
#   identity (the digest): the sha is what the graph IS, the path is where it was read from.
#   Same rule as `assets.sha256` vs `assets.path`.
#
# The migration is ADDITIVE. The two halves of the edge onto `renders` -- the column and its
# index, and the validation of the foreign keys added here -- are in the follow-up migration,
# because indexing a live table is not transaction-safe and because validating an FK into a
# pre-existing table must not happen under this migration's lock (strong_migrations enforces
# both, correctly).
class CreateContentConfigVersions < ActiveRecord::Migration[8.0]
  TRIGGERS_DIR = File.expand_path("../triggers", __dir__)

  def up
    create_table :content_config_versions do |t|
      t.bigint :content_pillar_id
      t.bigint :pipeline_step_id

      t.integer :wardrobe_level
      t.string :checkpoint
      t.text :negative_prompt
      t.string :workflow_sha256
      t.string :workflow_path

      # Derived from the pinned axes, never authored -- a version's identity is its content,
      # so a changed pin is a different row by construction. Assigned by the model's
      # `before_validation`, and unique so two identical configs cannot fork.
      t.string :digest, null: false

      t.timestamps
    end
    add_index :content_config_versions, :digest, unique: true
    add_index :content_config_versions, :content_pillar_id

    # Every foreign key here is added unvalidated and validated in the follow-up migration:
    # validation scans the referenced table under a lock, which this migration must not take.
    add_foreign_key :content_config_versions, :content_pillars, validate: false
    add_foreign_key :content_config_versions, :pipeline_steps, validate: false

    # The prompt in PARTS, exactly as the render records it: a part is the addressable unit,
    # and an assembled string cannot be varied.
    create_table :content_config_version_prompt_parts do |t|
      t.bigint :content_config_version_id, null: false
      t.string :name, null: false
      t.text :text
      t.string :text_sha256
      t.integer :position, null: false, default: 0

      t.timestamps
    end
    add_index :content_config_version_prompt_parts,
              [ :content_config_version_id, :name ],
              unique: true,
              name: "index_ccv_prompt_parts_on_version_and_name"
    add_foreign_key :content_config_version_prompt_parts, :content_config_versions, validate: false

    # The LoRA set with per-slot strengths. An OFF slot is a recorded fact, not an omission:
    # "off at 0.75" and "not in the graph at all" are different configs, and both `enabled`
    # and `strength` are nullable because where nobody recorded them the answer is UNKNOWN,
    # never false/0.
    create_table :content_config_version_loras do |t|
      t.bigint :content_config_version_id, null: false
      t.string :layer, null: false, default: "base"
      t.string :name, null: false
      t.decimal :strength, precision: 5, scale: 3
      t.boolean :enabled
      t.integer :position, null: false, default: 0

      t.timestamps
    end
    add_index :content_config_version_loras,
              [ :content_config_version_id, :layer, :name ],
              unique: true,
              name: "index_ccv_loras_on_version_and_layer_and_name"
    add_foreign_key :content_config_version_loras, :content_config_versions, validate: false

    # Append-only enforced by the DATABASE, because the model layer cannot see `update_all`,
    # `delete_all` or raw SQL. Applied from a shared file so the test database gets the same
    # guard -- see that file's header for why the SQL is not inline here.
    #
    # `safety_assured` is required because strong_migrations cannot classify an arbitrary
    # `execute`. Justification: both statements only CREATE OR REPLACE a function and attach
    # BEFORE UPDATE/DELETE triggers to the three tables THIS migration just created, which are
    # empty and unknown to any running process -- no pre-existing row is read, written or
    # locked, so the lock it takes cannot block anything.
    safety_assured do
      execute File.read(File.join(TRIGGERS_DIR, "content_config_version_immutability.sql"))
    end
  end

  def down
    # Dropping the tables drops their triggers with them; the function is last because the
    # triggers reference it. `renders.content_config_version_id` belongs to the follow-up
    # migration and is removed there.
    drop_table :content_config_version_loras
    drop_table :content_config_version_prompt_parts
    drop_table :content_config_versions

    execute "DROP FUNCTION IF EXISTS content_config_versions_are_append_only()"
  end
end
