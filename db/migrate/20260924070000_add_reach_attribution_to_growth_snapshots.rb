# frozen_string_literal: true

# Record WHERE the account's reach came from, not just how many followers it has.
#
# Root cause this closes (measured 2026-09-24): the pre-registered GO/PIVOT/KILL
# gate names "distribution/reach" as its pivot candidate, and the ONLY reach data
# this repo held was per-post (scheduling_posts.reach). Summing per-post reach
# cannot separate "the followers see every post" from "strangers find us", and
# those are different businesses: Growth::MetricsCollector recorded only
# `followers`, so whether ANY reach came from non-followers -- the single number
# that decides between a content problem and no distribution at all -- had never
# been measured.
#
# It is measurable: Instagram's account-level insights answer `reach` with
# `breakdown=follow_type`, and measured live on 2026-09-24 the account returned
# reach=6 with FOLLOWER=6 and NO NON_FOLLOWER row at all -- i.e. zero discovery,
# stated by the platform rather than inferred. `profile_views` is collected with
# it because a profile visit is the only step between reach and a follow.
#
# NULLABLE, and that is deliberate: NULL means the API did not answer (never
# measured), while 0 means a measured zero. Collapsing the two would let a broken
# call read as "no discovery" and manufacture exactly the verdict this data
# exists to support.
class AddReachAttributionToGrowthSnapshots < ActiveRecord::Migration[8.0]
  def change
    add_column :growth_snapshots, :follower_reach, :integer
    add_column :growth_snapshots, :non_follower_reach, :integer
    add_column :growth_snapshots, :reach_total, :integer
    add_column :growth_snapshots, :profile_views, :integer
  end
end