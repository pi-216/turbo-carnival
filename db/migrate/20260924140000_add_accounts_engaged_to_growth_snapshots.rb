# frozen_string_literal: true

# Record the PLATFORM'S OWN account-level engagement counter, so the
# acceptance counter stops being a claim only this repo can make.
#
# Root cause this closes (measured 2026-09-24): the open condition "nothing
# published in 14d was accepted: 0 like / 0 comment / 0 save across 22 measured
# posts at reach ~3/post" is read entirely from `scheduling_posts`, i.e. from
# numbers THIS APP collected. Every failure mode of that collection -- a media
# the insights endpoint refuses, a post whose insights never land, a metric set
# that misses an interaction type -- presents as the same flat zero, and no
# independent read existed to say which.
#
# Instagram answers that directly at the account level:
#   GET /{account_id}/insights?metric=accounts_engaged&period=day&metric_type=total_value
# -> "the number of accounts that have interacted with your content [...]
#     interactions can include actions such as likes, saves, comments, shares or
#     replies". Measured live 2026-09-24: value=0, which CORROBORATES the per-post
#     zero rather than merely agreeing with our own bookkeeping. It also rides
#     the SAME insights call as `profile_views` (metric=accounts_engaged,
#     profile_views returns HTTP 200 and both nodes), so this costs no extra API
#     round trip.
#
# NULLABLE deliberately: NULL means the API did not answer (never measured),
# never a measured zero -- the same rule as `reach_total` and `media_count` in
# this table. The period is ONE DAY, so the value is not comparable to the
# 14-day per-post window; it is a cross-check, not a replacement.
class AddAccountsEngagedToGrowthSnapshots < ActiveRecord::Migration[8.0]
  def change
    add_column :growth_snapshots, :accounts_engaged, :integer
  end
end
