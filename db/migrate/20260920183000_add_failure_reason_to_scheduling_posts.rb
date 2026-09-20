# frozen_string_literal: true

# Persist WHY a post failed.
#
# Root cause this closes (2026-09-20): a post Instagram REJECTED was
# indistinguishable from any other failed row. scheduled_posting.rake called
# mark_as_failed! with no argument, so the only record of the cause -- Instagram
# 400 code 9007 "Media ID is not available: the media is not ready for
# publishing" (a container-readiness race) -- was a line in
# log/scheduled_posting.log. That log rotates away, and no DB-side check reads
# it, so bin/tc_ops.py's silent-failure detector (check_publish_failed_silent)
# could report that a slot was lost but never why, and the retry decision
# (deliberately Tim's call, since it changes live publish behaviour) could not
# be made from data.
#
# Nullable and additive: every pre-existing row keeps failure_reason NULL.
class AddFailureReasonToSchedulingPosts < ActiveRecord::Migration[8.0]
  def change
    add_column :scheduling_posts, :failure_reason, :text
  end
end
