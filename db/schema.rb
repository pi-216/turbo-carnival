# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2026_09_24_070000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "comfyui_jobs", force: :cascade do |t|
    t.bigint "image_candidate_id"
    t.bigint "pipeline_run_id", null: false
    t.bigint "pipeline_step_id", null: false
    t.string "comfyui_job_id"
    t.string "status", default: "pending", null: false
    t.jsonb "job_payload", null: false
    t.jsonb "result_metadata"
    t.text "error_message"
    t.integer "retry_count", default: 0, null: false
    t.datetime "submitted_at"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "parent_candidate_id"
    t.index ["comfyui_job_id"], name: "index_comfyui_jobs_on_comfyui_job_id"
    t.index ["image_candidate_id"], name: "index_comfyui_jobs_on_image_candidate_id"
    t.index ["job_payload"], name: "index_comfyui_jobs_on_job_payload", using: :gin
    t.index ["parent_candidate_id"], name: "index_comfyui_jobs_on_parent_candidate_id"
    t.index ["pipeline_run_id"], name: "index_comfyui_jobs_on_pipeline_run_id"
    t.index ["pipeline_step_id"], name: "index_comfyui_jobs_on_pipeline_step_id"
    t.index ["status"], name: "index_comfyui_jobs_on_status"
  end

  create_table "content_pillars", force: :cascade do |t|
    t.bigint "persona_id", null: false
    t.string "name", null: false
    t.text "description"
    t.decimal "weight", precision: 5, scale: 2, default: "0.0", null: false
    t.boolean "active", default: true, null: false
    t.date "start_date"
    t.date "end_date"
    t.jsonb "guidelines", default: {}
    t.integer "target_posts_per_week"
    t.integer "priority", default: 3, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_content_pillars_on_active"
    t.index ["persona_id", "name"], name: "index_content_pillars_on_persona_id_and_name", unique: true
    t.index ["persona_id"], name: "index_content_pillars_on_persona_id"
    t.check_constraint "end_date IS NULL OR start_date IS NULL OR end_date > start_date", name: "date_range_check"
    t.check_constraint "priority >= 1 AND priority <= 5", name: "priority_range_check"
    t.check_constraint "weight >= 0::numeric AND weight <= 100::numeric", name: "weight_range_check"
  end

  create_table "content_strategy_histories", force: :cascade do |t|
    t.bigint "persona_id", null: false
    t.bigint "post_id"
    t.string "strategy_name", null: false
    t.jsonb "decision_context", default: {}, null: false
    t.datetime "created_at", null: false
    t.index ["created_at"], name: "index_content_strategy_histories_on_created_at"
    t.index ["persona_id"], name: "index_content_strategy_histories_on_persona_id"
    t.index ["post_id"], name: "index_content_strategy_histories_on_post_id"
    t.index ["strategy_name"], name: "index_content_strategy_histories_on_strategy_name"
  end

  create_table "content_strategy_states", force: :cascade do |t|
    t.bigint "persona_id", null: false
    t.string "active_strategy", default: "thematic_rotation_strategy", null: false
    t.jsonb "strategy_config", default: {}, null: false
    t.jsonb "state_data", default: {}, null: false
    t.datetime "started_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "pillar_engagement_scores", default: {}
    t.jsonb "selection_history", default: []
    t.jsonb "last_adjustment", default: []
    t.datetime "last_adjustment_at"
    t.index ["persona_id"], name: "index_content_strategy_states_on_persona_id", unique: true
  end

  create_table "content_suggestions", force: :cascade do |t|
    t.bigint "gap_analysis_id", null: false
    t.bigint "content_pillar_id", null: false
    t.string "title"
    t.text "description"
    t.jsonb "prompt_data"
    t.string "status", default: "pending"
    t.datetime "used_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["content_pillar_id"], name: "index_content_suggestions_on_content_pillar_id"
    t.index ["gap_analysis_id"], name: "index_content_suggestions_on_gap_analysis_id"
  end

  create_table "gap_analyses", force: :cascade do |t|
    t.bigint "persona_id", null: false
    t.datetime "analyzed_at"
    t.jsonb "coverage_data"
    t.jsonb "recommendations"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["persona_id"], name: "index_gap_analyses_on_persona_id"
  end

  create_table "growth_decisions", force: :cascade do |t|
    t.bigint "goal_id", null: false
    t.bigint "snapshot_id"
    t.string "action", null: false
    t.string "reason"
    t.jsonb "from_values", default: {}, null: false
    t.jsonb "to_values", default: {}, null: false
    t.datetime "decided_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decided_at"], name: "index_growth_decisions_on_decided_at"
    t.index ["goal_id"], name: "index_growth_decisions_on_goal_id"
  end

  create_table "growth_goals", force: :cascade do |t|
    t.bigint "persona_id", null: false
    t.string "instagram_handle"
    t.integer "target_followers", default: 1000, null: false
    t.date "deadline"
    t.integer "start_followers", default: 0, null: false
    t.integer "posts_per_day", default: 1, null: false
    t.integer "max_posts_per_day", default: 3, null: false
    t.integer "hashtag_count", default: 10, null: false
    t.integer "review_interval_days", default: 7, null: false
    t.datetime "last_reviewed_at"
    t.string "status", default: "active", null: false
    t.jsonb "strategy_config", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["persona_id"], name: "index_growth_goals_on_persona_id"
    t.index ["status"], name: "index_growth_goals_on_status"
  end

  create_table "growth_reviews", force: :cascade do |t|
    t.bigint "goal_id", null: false
    t.datetime "reviewed_at", null: false
    t.integer "followers", default: 0
    t.integer "followers_delta"
    t.decimal "required_daily", precision: 8, scale: 2
    t.decimal "measured_daily", precision: 8, scale: 2
    t.decimal "trajectory_ratio", precision: 6, scale: 3
    t.string "verdict", null: false
    t.jsonb "pillar_engagement", default: {}
    t.jsonb "top_pillars", default: []
    t.string "persona_direction"
    t.jsonb "recommendations", default: []
    t.jsonb "applied_changes", default: []
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["goal_id"], name: "index_growth_reviews_on_goal_id"
    t.index ["reviewed_at"], name: "index_growth_reviews_on_reviewed_at"
  end

  create_table "growth_snapshots", force: :cascade do |t|
    t.bigint "goal_id", null: false
    t.integer "followers", null: false
    t.datetime "taken_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "follower_reach"
    t.integer "non_follower_reach"
    t.integer "reach_total"
    t.integer "profile_views"
    t.index ["goal_id"], name: "index_growth_snapshots_on_goal_id"
    t.index ["taken_at"], name: "index_growth_snapshots_on_taken_at"
  end

  create_table "image_candidates", force: :cascade do |t|
    t.bigint "pipeline_step_id", null: false
    t.bigint "parent_id"
    t.string "image_path"
    t.integer "elo_score", default: 1000, null: false
    t.string "status", default: "active", null: false
    t.integer "child_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "pipeline_run_id"
    t.integer "vote_count", default: 0, null: false
    t.integer "failure_count", default: 0, null: false
    t.boolean "winner", default: false, null: false
    t.datetime "winner_at"
    t.float "quality_score"
    t.jsonb "quality_metrics"
    t.float "engagement_score"
    t.index ["elo_score"], name: "index_image_candidates_on_elo_score"
    t.index ["parent_id"], name: "index_image_candidates_on_parent_id"
    t.index ["pipeline_run_id"], name: "index_image_candidates_on_pipeline_run_id"
    t.index ["pipeline_step_id"], name: "index_image_candidates_on_pipeline_step_id"
    t.index ["status", "child_count"], name: "index_image_candidates_on_status_and_child_count"
    t.index ["vote_count"], name: "index_image_candidates_on_vote_count"
    t.index ["winner"], name: "index_image_candidates_on_winner"
  end

  create_table "personas", force: :cascade do |t|
    t.string "name"
    t.jsonb "caption_config"
    t.jsonb "hashtag_strategy"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "photos", force: :cascade do |t|
    t.bigint "persona_id", null: false
    t.string "path", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "image_candidate_id"
    t.bigint "content_pillar_id"
    t.boolean "synthetic"
    t.jsonb "provenance", default: {}
    t.index ["content_pillar_id"], name: "index_photos_on_content_pillar_id"
    t.index ["image_candidate_id"], name: "index_photos_on_image_candidate_id", unique: true
    t.index ["path"], name: "index_photos_on_path", unique: true
    t.index ["persona_id"], name: "index_photos_on_persona_id"
  end

  create_table "pipeline_run_steps", force: :cascade do |t|
    t.bigint "pipeline_run_id", null: false
    t.bigint "pipeline_step_id", null: false
    t.boolean "approved", default: false, null: false
    t.datetime "approved_at"
    t.integer "top_k_count", default: 3, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["pipeline_run_id", "pipeline_step_id"], name: "index_pipeline_run_steps_on_run_and_step", unique: true
    t.index ["pipeline_run_id"], name: "index_pipeline_run_steps_on_pipeline_run_id"
    t.index ["pipeline_step_id"], name: "index_pipeline_run_steps_on_pipeline_step_id"
  end

  create_table "pipeline_runs", force: :cascade do |t|
    t.bigint "pipeline_id", null: false
    t.string "name"
    t.string "target_folder"
    t.jsonb "variables", default: {}, null: false
    t.string "status", default: "pending", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "prompt"
    t.bigint "persona_id"
    t.bigint "content_pillar_id"
    t.integer "oom_retries", default: 0, null: false
    t.jsonb "quality_metrics", default: {}
    t.text "reject_reason"
    t.index ["content_pillar_id"], name: "index_pipeline_runs_on_content_pillar_id"
    t.index ["persona_id"], name: "index_pipeline_runs_on_persona_id"
    t.index ["pipeline_id"], name: "index_pipeline_runs_on_pipeline_id"
    t.index ["status"], name: "index_pipeline_runs_on_status"
    t.index ["variables"], name: "index_pipeline_runs_on_variables", using: :gin
  end

  create_table "pipeline_steps", force: :cascade do |t|
    t.bigint "pipeline_id", null: false
    t.string "name", null: false
    t.integer "order", null: false
    t.text "comfy_workflow_json", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "needs_run_prompt", default: false, null: false
    t.boolean "needs_parent_image_path", default: false, null: false
    t.boolean "needs_run_variables", default: false, null: false
    t.integer "max_children", default: 3, null: false
    t.index ["pipeline_id", "order"], name: "index_pipeline_steps_on_pipeline_id_and_order", unique: true
    t.index ["pipeline_id"], name: "index_pipeline_steps_on_pipeline_id"
  end

  create_table "pipelines", force: :cascade do |t|
    t.string "name", null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_pipelines_on_name"
  end

  create_table "scheduling_posts", force: :cascade do |t|
    t.bigint "photo_id"
    t.bigint "persona_id", null: false
    t.text "caption"
    t.string "status", default: "draft", null: false
    t.string "provider_post_id"
    t.datetime "scheduled_at"
    t.datetime "posted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "strategy_name"
    t.datetime "optimal_time_calculated"
    t.jsonb "hashtags", default: []
    t.jsonb "caption_metadata"
    t.bigint "content_suggestion_id"
    t.bigint "pipeline_run_id"
    t.integer "likes_count"
    t.integer "comments_count"
    t.integer "reach"
    t.integer "saved_count"
    t.float "engagement_rate"
    t.datetime "insights_updated_at"
    t.text "failure_reason"
    t.datetime "insights_unavailable_at"
    t.index ["content_suggestion_id"], name: "index_scheduling_posts_on_content_suggestion_id"
    t.index ["persona_id"], name: "index_scheduling_posts_on_persona_id"
    t.index ["photo_id", "persona_id"], name: "index_posts_on_photo_id_and_persona_id", unique: true
    t.index ["photo_id"], name: "index_scheduling_posts_on_missing_photo", where: "(photo_id IS NULL)"
    t.index ["photo_id"], name: "index_scheduling_posts_on_photo_id"
    t.index ["pipeline_run_id"], name: "index_scheduling_posts_on_pipeline_run_id"
    t.index ["strategy_name"], name: "index_scheduling_posts_on_strategy_name"
  end

  create_table "votes", force: :cascade do |t|
    t.integer "winner_id", null: false
    t.integer "loser_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["loser_id"], name: "index_votes_on_loser_id"
    t.index ["winner_id", "loser_id"], name: "index_votes_on_winner_id_and_loser_id", unique: true
    t.index ["winner_id"], name: "index_votes_on_winner_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "comfyui_jobs", "image_candidates"
  add_foreign_key "comfyui_jobs", "image_candidates", column: "parent_candidate_id"
  add_foreign_key "comfyui_jobs", "pipeline_runs"
  add_foreign_key "comfyui_jobs", "pipeline_steps"
  add_foreign_key "content_pillars", "personas"
  add_foreign_key "content_strategy_histories", "personas"
  add_foreign_key "content_strategy_histories", "scheduling_posts", column: "post_id"
  add_foreign_key "content_strategy_states", "personas"
  add_foreign_key "content_suggestions", "content_pillars"
  add_foreign_key "content_suggestions", "gap_analyses"
  add_foreign_key "gap_analyses", "personas"
  add_foreign_key "image_candidates", "image_candidates", column: "parent_id"
  add_foreign_key "image_candidates", "pipeline_runs"
  add_foreign_key "image_candidates", "pipeline_steps"
  add_foreign_key "photos", "content_pillars"
  add_foreign_key "photos", "image_candidates"
  add_foreign_key "photos", "personas"
  add_foreign_key "pipeline_run_steps", "pipeline_runs"
  add_foreign_key "pipeline_run_steps", "pipeline_steps"
  add_foreign_key "pipeline_runs", "content_pillars"
  add_foreign_key "pipeline_runs", "personas"
  add_foreign_key "pipeline_runs", "pipelines"
  add_foreign_key "pipeline_steps", "pipelines"
  add_foreign_key "scheduling_posts", "content_suggestions"
  add_foreign_key "scheduling_posts", "personas"
  add_foreign_key "scheduling_posts", "photos"
  add_foreign_key "scheduling_posts", "pipeline_runs"
  add_foreign_key "votes", "image_candidates", column: "loser_id"
  add_foreign_key "votes", "image_candidates", column: "winner_id"
end
