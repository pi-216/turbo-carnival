# frozen_string_literal: true

# #39 (option B, founder ruling 2026-10-19): the per-post instrument.
#
# Instagram exposes NO per-post follower/non-follower split -- measured 2026-10-19,
# every media-level `follow_type` breakdown answers 400 (#100) on v19.0-v24.0 while the
# account-level one answers 200. So the per-post instrument is the metrics the platform
# DOES report per post, and non-follower reach stays the account/day measurement it
# already is on growth_snapshots.
#
# All three columns are NULLABLE on purpose. NULL is "not measured / not applicable",
# and the red line is that a stored 0 and a missing measurement are different facts: a
# reel has no `follows` at all, so storing 0 there would invent a measurement.
class AddPerPostInsightsAndRenderLink < ActiveRecord::Migration[8.0]
  def change
    add_column :scheduling_posts, :views, :integer
    add_column :scheduling_posts, :follows, :integer
    add_column :scheduling_posts, :profile_visits, :integer

    # The edge that makes "reach by the render that produced it" a query instead of a
    # hand-kept mapping: post -> photo -> image_candidate -> render.
    #
    # Unique because a render produces exactly one candidate, and because a non-unique
    # index would let one candidate be linked to two renders and silently double-count
    # that render's reach in Growth::RenderReach.
    add_column :renders, :image_candidate_id, :bigint
    add_index :renders, :image_candidate_id, unique: true
  end
end
