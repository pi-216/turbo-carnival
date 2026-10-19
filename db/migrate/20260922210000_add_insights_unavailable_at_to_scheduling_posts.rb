# frozen_string_literal: true

# Terminal-state marker for the engagement feedback path.
#
# CollectPostInsights answers 400/code 100 ("media deleted or inaccessible")
# forever for a handful of posts, and until now nothing recorded that verdict --
# so those rows stayed "never collected" and, because the selection orders
# never-collected rows first, they re-entered EVERY run and spent 11 of its
# 25-row budget on API calls that can never succeed. Measured 2026-09-22: 11 such
# rows (ids 133-143, 148) and 55 identical "can never be refreshed ... they
# re-enter every run" warnings in log/development.log.
#
# insights_unavailable_at records WHEN the API last said the media is
# unreachable. It is a BACKOFF, not a tombstone: the selection re-probes a marked
# row after the retry window, so a token/permission change that makes an old media
# readable again is picked up, while the per-run waste stops. Reversible by
# setting the column back to NULL.
class AddInsightsUnavailableAtToSchedulingPosts < ActiveRecord::Migration[8.0]
  def change
    add_column :scheduling_posts, :insights_unavailable_at, :datetime
  end
end
