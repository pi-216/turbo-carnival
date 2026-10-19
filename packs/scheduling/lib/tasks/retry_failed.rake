# frozen_string_literal: true

namespace :scheduling do
  desc 'Re-book the slot of a post Instagram rejected with a TRANSIENT error ' \
       '(dry-run by default; APPLY=1 to write, LIMIT=n to bound the batch)'
  task retry_failed: :environment do
    # WHY THIS EXISTS
    # A rejected post used to lose its slot forever: `failed` is terminal, the
    # (photo_id, persona_id) index is unique so no replacement row can exist, and
    # nothing re-booked the row. See Scheduling::FailedPostRetry for the rule
    # (transient causes only, one retry per row). DRY RUN by default, because the
    # service writes to live publishing rows; bin/scheduled_posting.sh runs it with
    # APPLY=1 ahead of the publisher, the same way the caption and hashtag repairs
    # are wired. NON-FATAL there: a repair failure must never stall publishing.
    apply = ENV['APPLY'].to_s == '1'
    limit = (ENV['LIMIT'] || 3).to_i

    result = Scheduling::FailedPostRetry.new(dry_run: !apply).call(limit: limit)

    puts "FailedPostRetry: examined=#{result.examined} " \
         "requeued=#{result.requeued} skipped=#{result.skipped} " \
         "posts=#{result.post_ids.inspect}"
    result.reasons.each { |reason| puts "   - #{reason}" }

    unless apply
      puts 'DRY RUN -- nothing written. Re-run with APPLY=1 to re-book these posts.'
    end
  end
end
