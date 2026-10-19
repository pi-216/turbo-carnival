# frozen_string_literal: true

module Scheduling
  # Which of the posts that are DUE right now go out in THIS run.
  #
  # Why this exists: `scheduling:post_scheduled` released EVERY due post in a
  # single pass, and it is driven hourly (bin/scheduled_posting.sh, user crontab
  # `0 * * * *`). A healthy queue has at most one post due per tick -- producers
  # allocate slots >= 90 min apart -- so the single pass only shows up as a burst
  # when slots are bunched: measured 2026-09-19 four posts inside 90 min, and the
  # pre-fix residue puts two slots 14 min apart on every day through 09-25.
  # Releasing them together is what "3 pair(s) of posts inside 60 min" on the ops
  # board actually means at the account.
  #
  # Why deferral and not a reschedule: a deferred post is NOT dropped and NOT
  # failed. It keeps status='scheduled' with a past scheduled_at, so the next run
  # selects it first -- deferral can only ever delay a post, never lose one. That
  # is the property that makes this safe on the one path that must never stall
  # (a stalled publisher is the worst failure class on the ops board).
  #
  # Ordering is the CALLER's job: it owns the publisher's own selection predicate
  # and passes the rows already sorted by slot ascending.
  class PostReleasePlan
    MAX_PER_RUN = 1

    Plan = Struct.new(:released, :deferred, keyword_init: true)

    def self.call(due_posts, max_per_run: MAX_PER_RUN)
      new(max_per_run: max_per_run).call(due_posts)
    end

    def initialize(max_per_run: MAX_PER_RUN)
      @max_per_run = max_per_run
    end

    def call(due_posts)
      posts = due_posts.to_a
      released = posts.first(@max_per_run)
      Plan.new(released: released, deferred: posts - released)
    end
  end
end
