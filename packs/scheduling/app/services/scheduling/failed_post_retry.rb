# frozen_string_literal: true

module Scheduling
  # Re-book the SLOT of a post Instagram rejected.
  #
  # WHY THIS EXISTS
  # The publisher's failure path is `post.record_failure!(reason)`: the row goes to
  # `failed` and STOPS. `failed` is terminal in the state machine, the unique index
  # on (photo_id, persona_id) means no second row can be created for the same photo,
  # and nothing else in the pipeline ever looks at a `failed` row -- so a rejected
  # post loses BOTH its slot and its (already paid-for) render permanently. Measured:
  # three lifetime occurrences (posts 37, 246, 333); the newest was 2026-09-20 15:15Z
  # (400 code 9007, a container-readiness race that survived the 4x/10s publish retry
  # added in ffe9692). The publisher still exits 0, so the loss reads as a clean run.
  #
  # RULE: retry only what the failure reason itself classifies as TRANSIENT, and never
  # more than once per row. A policy rejection -- or any 4xx that is not the known
  # readiness race -- is a decision, not a hiccup: re-booking it would re-offer
  # rejected content to the platform, so those rows stay `failed` and stay on the ops
  # board for a human. See TRANSIENT_PATTERNS.
  #
  # Why the row is RE-USED instead of a new one being created:
  #   * `index_posts_on_photo_id_and_persona_id` is UNIQUE, so a second row for the
  #     same photo is impossible without a schema change or a fake photo;
  #   * the row already carries the caption, hashtags, caption_metadata, photo and
  #     pipeline_run that were paid for -- the retry is a slot, not a re-render;
  #   * `failed` is terminal in the state machine, so the status is written directly,
  #     the same way `record_failure!` writes failure_reason.
  # The attempt is recorded IN failure_reason (bounded, append-only), which makes the
  # retry auditable and idempotent: a row already carrying RETRY_MARKER is skipped, so
  # re-running this service can never book a second slot for one failure.
  class FailedPostRetry
    # Attempt marker written into failure_reason. Also the ops board's signal that a
    # failed row is no longer a lost slot (bin/tc_ops.py check_publish_failed_silent).
    RETRY_MARKER = 'retry#'
    MAX_RETRIES = 1
    # A failure older than this is history, not an incident: the queue has moved on and
    # the photo may already have been superseded.
    WINDOW = 24.hours
    # Fallback cadence when the persona has no active goal to size the queue against.
    DEFAULT_POSTS_PER_DAY = 3
    FAILURE_REASON_MAX = Scheduling::Post::FAILURE_REASON_MAX

    # Transient classes only. Everything else is a decision (policy, permissions,
    # invalid media, token) and is deliberately NOT retried.
    TRANSIENT_PATTERNS = [
      /\b9007\b/,                       # media not ready for publishing
      /\b2207027\b/,                    # the matching API subcode
      /timed?\s?out/i,
      /timeout/i,
      /\b429\b/,                        # rate limited
      /\b5\d\d\b/,                      # server error
      /temporarily unavailable/i,
      /connection (reset|closed|refused)/i,
      /url_generation:/i                # our own public-URL step, before the API
    ].freeze

    Result = Struct.new(:examined, :requeued, :skipped, :post_ids, :reasons,
                        keyword_init: true)

    # @param dry_run [Boolean] when true nothing is written and `requeued` counts the
    #   rows that WOULD be re-booked -- the rake task's default, because this writes
    #   to live publishing rows.
    def initialize(logger: Rails.logger, dry_run: false)
      @logger = logger
      @dry_run = dry_run
    end

    # @param limit [Integer] max rows to re-book in this call
    def call(limit: 3)
      result = Result.new(examined: 0, requeued: 0, skipped: 0, post_ids: [], reasons: [])
      limit = limit.to_i
      return result if limit <= 0

      candidates.each do |post|
        break if result.requeued >= limit

        result.examined += 1
        skip_reason = skip_reason_for(post)
        if skip_reason
          result.skipped += 1
          result.reasons << "post #{post.id}: #{skip_reason}"
          next
        end

        if requeue(post)
          result.requeued += 1
          result.post_ids << post.id
        else
          result.skipped += 1
          result.reasons << "post #{post.id}: requeue failed"
        end
      end

      if result.requeued.positive?
        @logger.info("Scheduling::FailedPostRetry re-booked #{result.requeued} rejected post(s): #{result.post_ids.inspect}")
      end
      result
    rescue StandardError => e
      # Never let a repair break the publisher it is bolted onto.
      @logger.error("Scheduling::FailedPostRetry failed: #{e.class} - #{e.message}")
      result
    end

    private

    def candidates
      Scheduling::Post
        .where(status: 'failed')
        .where('updated_at > ?', WINDOW.ago)
        .order(:updated_at)
    end

    # nil = eligible. Everything else is the reason this row must stay failed.
    def skip_reason_for(post)
      reason = post.failure_reason.to_s
      return 'no failure reason stored (cannot classify the cause)' if reason.strip.empty?
      return 'already retried' if retried?(reason)
      return 'not a transient failure (policy/permission decision)' unless transient?(reason)

      photo = post.photo
      return 'no photo row' if photo.nil?
      return 'photo file is gone' unless photo_servable?(photo)

      nil
    end

    def retried?(reason)
      reason.scan(/#{Regexp.escape(RETRY_MARKER)}(\d+)/).flatten
            .map(&:to_i).max.to_i >= MAX_RETRIES
    end

    def transient?(reason)
      TRANSIENT_PATTERNS.any? { |pattern| reason.match?(pattern) }
    end

    # Same servability test the salvage path uses: the file the publisher will ask
    # Instagram to fetch must still be on disk.
    def photo_servable?(photo)
      path = photo.path.to_s
      !path.empty? && File.file?(path)
    end

    def requeue(post)
      slot = Growth::PostSlotPlanner.next_slot(
        persona: post.persona,
        posts_per_day: posts_per_day_for(post)
      )
      if @dry_run
        @logger.info("Scheduling::FailedPostRetry DRY RUN: post #{post.id} (photo #{post.photo_id}) would be re-booked for #{slot.utc.iso8601}")
        return true
      end

      attempt = next_attempt(post)
      original = post.failure_reason.to_s.strip
      note = "#{RETRY_MARKER}#{attempt} re-booked #{slot.utc.iso8601} | #{original}"
      post.update!(
        status: 'scheduled',
        scheduled_at: slot,
        optimal_time_calculated: slot,
        failure_reason: note.truncate(FAILURE_REASON_MAX)
      )
      @logger.warn("Scheduling::FailedPostRetry re-booked post #{post.id} (photo #{post.photo_id}) for #{slot.utc.iso8601}")
      true
    rescue StandardError => e
      @logger.warn("Scheduling::FailedPostRetry could not re-book post #{post.id}: #{e.class} - #{e.message}")
      false
    end

    def next_attempt(post)
      seen = post.failure_reason.to_s.scan(/#{Regexp.escape(RETRY_MARKER)}(\d+)/).flatten
      seen.map(&:to_i).max.to_i + 1
    end

    def posts_per_day_for(post)
      goal = Growth::Goal.for_persona(post.persona).order(:id).last
      goal&.effective_posts_per_day || DEFAULT_POSTS_PER_DAY
    rescue StandardError
      DEFAULT_POSTS_PER_DAY
    end
  end
end
