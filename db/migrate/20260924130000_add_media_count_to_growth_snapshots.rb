# frozen_string_literal: true

# Record the account's OWN media inventory, so a platform-side REMOVAL stops
# being invisible.
#
# Root cause this closes (measured 2026-09-24): every engagement read in this
# repo is keyed on post ids THIS APP recorded. `provider_post_id` is written
# once, at publish time, and never re-checked -- so if Instagram takes a post
# down, the DB row still says "posted", the post still counts toward the queue
# runway and the 14-day acceptance counter, and nothing anywhere errors while
# the account's live inventory shrinks underneath. The zero-engagement read (0
# like / 0 comment / 0 save across 22 measured posts, reach ~3/post) has the
# shape of a distribution failure AND the shape of removed content, and no probe
# could tell the two apart.
#
# Measured live 2026-09-24 before adding this: the platform reports media_count
# 224 against 149 posts this app believes it published, and the newest 10
# published posts are all still retrievable with like_count/comments_count = 0
# agreeing with our own columns -- i.e. no removal is happening NOW, but that
# was a hand-run check that nothing repeats.
#
# `media_count` is collected beside `followers` (same account node, same call
# shape, no extra API round trip). Publishing can only INCREASE it, so a
# DECREASE between snapshots is a removal stated by the platform rather than
# inferred from our bookkeeping. NULLABLE deliberately: NULL means the API did
# not answer (never measured), never a measured zero.
class AddMediaCountToGrowthSnapshots < ActiveRecord::Migration[8.0]
  def change
    add_column :growth_snapshots, :media_count, :integer
  end
end