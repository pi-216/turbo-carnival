# frozen_string_literal: true

# The attribution spine: what produced an asset, and how it was measured.
#
# WHY THIS EXISTS
# ---------------
# PRD 0002 (plan item W1.2). The render inputs exist today but not as data: the seed and
# checkpoint live inside `pipeline_runs.variables` (jsonb, GIN-indexed), the assembled prompt
# lives in `pipeline_runs.prompt` (a text blob), and the graph lives twice
# (`pipeline_steps.comfy_workflow_json` AND `comfy_workflows/` on disk). None of that can be
# grouped, filtered or joined -- so "which checkpoint / LoRA / sampler / prompt-part
# combination produced the assets that earned the most non-follower reach?" is not a hard
# query today, it is an impossible one. This migration makes those values rows and columns.
#
# WHAT IS DELIBERATELY *NOT* HERE
# -------------------------------
# * `photos.provenance` is untouched and unread. It is the synthetic-mark COMPLIANCE ledger
#   (legal floor), and mixing a legal record into an experiment record would make the legal
#   one collateral damage of a schema change. The spine carries no provenance/embedded column
#   as a guard, and a spec asserts that.
# * NOTHING IS BACKFILLED. The corpus holds hundreds of posts and thousands of candidates
#   with no recorded inputs. A guessed checkpoint is worse than an absent one: it silently
#   poisons every later query. Unknown stays unknown, which is why every input column here is
#   nullable and why nothing is defaulted to 0 or "".
# * No assembled-prompt column. The prompt is stored as named parts (`render_prompt_parts`)
#   because a part can be varied and a blob cannot. The negative is the one exception: it is a
#   single scalar per render, so it is a column, and `render_prompt_parts` refuses the name
#   "negative" so that fact has exactly one home.
#
# DESIGN NOTES A READER WILL ASK ABOUT
# ------------------------------------
# * `assets.sha256` is NOT the primary key, it is a UNIQUE NOT NULL column. "Content-addressed"
#   is the invariant that one row exists per distinct content, and the unique index is what
#   enforces it (`Attribution::Asset.record` is the idempotent upsert). Every other table in
#   this schema uses a bigint id, so a string PK would be the only exception and would fight
#   ActiveRecord's associations for no gain.
# * `assets.path` is deliberately NOT unique: a path is a location that gets re-used (a
#   re-render overwrites a file), so identity is the hash and the path is the last known place.
# * The migration is ADDITIVE. Nothing existing is renamed or dropped, and no existing table is
#   altered, so a rollback cannot lose data.
class CreateAttributionSpine < ActiveRecord::Migration[8.0]
  def change
    create_table :assets do |t|
      t.string :sha256, null: false
      t.string :kind, null: false, default: "image"
      t.string :path
      t.bigint :byte_size
      t.integer :width
      t.integer :height
      t.integer :duration_ms

      t.timestamps
    end
    add_index :assets, :sha256, unique: true
    add_index :assets, :path

    create_table :renders do |t|
      t.bigint :asset_id
      t.bigint :pipeline_run_id

      t.bigint :seed
      t.string :checkpoint
      t.string :sampler
      t.string :scheduler
      t.integer :steps
      t.decimal :cfg, precision: 6, scale: 2
      t.decimal :denoise, precision: 4, scale: 3
      t.integer :width
      t.integer :height
      t.text :negative_prompt

      t.string :workflow_sha256
      t.string :workflow_path
      t.datetime :produced_at

      t.timestamps
    end
    add_index :renders, :asset_id
    add_index :renders, :pipeline_run_id
    add_foreign_key :renders, :assets
    add_foreign_key :renders, :pipeline_runs

    # The prompt in PARTS: each part a named, addressable field, so one of them can be varied.
    create_table :render_prompt_parts do |t|
      t.bigint :render_id, null: false
      t.string :name, null: false
      t.text :text
      t.string :text_sha256
      t.integer :position, null: false, default: 0

      t.timestamps
    end
    add_index :render_prompt_parts, [ :render_id, :name ], unique: true
    add_index :render_prompt_parts, :text_sha256
    add_foreign_key :render_prompt_parts, :renders

    # The LoRA set with per-slot strengths. Rows, not a blob: "which LoRA produced the reach"
    # is a join, and an off slot is a recorded fact (its strength is inert but real).
    # `strength` and `enabled` are both nullable on purpose: an axis nobody recorded reads as
    # NULL, never as 0 / false. (The `layer` default IS a structural label, not a measurement --
    # a render's primary LoRA set drives the base pass.)
    create_table :render_loras do |t|
      t.bigint :render_id, null: false
      t.string :layer, null: false, default: "base"
      t.string :name, null: false
      t.decimal :strength, precision: 5, scale: 3
      t.boolean :enabled
      t.integer :position, null: false, default: 0

      t.timestamps
    end
    add_index :render_loras, [ :render_id, :layer, :name ], unique: true
    add_foreign_key :render_loras, :renders

    # Per-render metrics, keyed to the render AND to the assessor (model + version). Two
    # versions of one assessor are two different measurements and must not collide.
    create_table :assessments do |t|
      t.bigint :render_id, null: false
      t.string :assessor_model, null: false
      t.string :assessor_version, null: false
      t.string :metric, null: false
      t.decimal :value
      t.datetime :assessed_at

      t.timestamps
    end
    add_index :assessments,
              [ :render_id, :assessor_model, :assessor_version, :metric ],
              unique: true,
              name: "index_assessments_on_render_and_assessor_and_metric"
    add_index :assessments, :metric
    add_foreign_key :assessments, :renders
  end
end
