# frozen_string_literal: true

module ContentStrategy
  # Fill the hashtags on posts that are still queued and have none.
  #
  # The hashtag chain was broken for the account's whole life -- all 197 posted
  # items went out with ZERO tags -- and was repaired on 2026-09-19 in four
  # places (HashtagEngine's pillar split, Personas::HashtagStrategy#tags, the
  # generator's create, and the publisher's caption). Every one of those fixes is
  # on the PRODUCER side, so a row already in the queue keeps its empty
  # `hashtags` and the publisher appends nothing to the caption: the queue-side
  # artifact survives the fix for the outage that wrote it. Measured 2026-09-20:
  # post 340 (slot 09-24 17:50Z) was created two minutes AFTER the fix by a
  # process still running pre-fix code, and no probe could see it -- the hashtag
  # probes measure the producer window and the send path reads the column as-is.
  #
  # This is the exact counterpart of CaptionGeneration::PlaceholderRefresh (the
  # repair the publisher runs for the placeholder caption), and it is safe for
  # the same reason: a post that is still draft/scheduled and still in the future
  # has not been sent, so filling its hashtags changes nothing that has already
  # happened. The publisher runs it with APPLY=1 ahead of
  # scheduling:post_scheduled, so a missed row heals at the next tick.
  #
  # DRY-RUN BY DEFAULT. Hashtags are part of what the public account will say, so
  # the write path is opt-in (APPLY=1 via rake, or dry_run: false) and never
  # silent -- same contract as the caption repair.
  class QueuedHashtagBackfill
    UNPUBLISHED_STATUSES = %w[draft scheduled].freeze
    # The count every producer uses (Growth::ContentGenerator and
    # Growth::RenderSalvage both ask the engine for 10), so a repaired post is
    # indistinguishable from a freshly produced one.
    HASHTAG_COUNT = 10

    Result = Struct.new(:post_id, :outcome, :hashtags, :error, keyword_init: true)

    def self.call(dry_run: true, persona: nil, now: Time.current, include_due: false)
      new(persona: persona, now: now).call(dry_run: dry_run, include_due: include_due)
    end

    def initialize(persona: nil, now: Time.current)
      @persona = persona
      @now = now
    end

    # Unpublished posts whose `hashtags` column is empty, in publish order.
    # `optimal_time_calculated` is the publisher's other clock for draft rows, so
    # both are used -- the same predicate scheduling:post_scheduled selects on.
    #
    # `include_due` widens this to a row that is ALREADY past its slot, which is
    # what the publisher needs: a tick that is late, or a slot that passes
    # between two ticks, would otherwise publish the untagged row because the
    # pre-publish repair skipped it as "already due".
    def candidates(include_due: false)
      scope = Scheduling::Post.where(status: UNPUBLISHED_STATUSES)
      scope = scope.where(persona: @persona) if @persona
      scope = scope.where('scheduled_at > ? OR optimal_time_calculated > ?', @now, @now) unless include_due
      scope.where("jsonb_array_length(coalesce(hashtags, '[]'::jsonb)) = 0")
           .order(:scheduled_at)
    end

    def call(dry_run: true, include_due: false)
      candidates(include_due: include_due).map { |post| fill(post, dry_run: dry_run) }
    end

    private

    def fill(post, dry_run:)
      tags = ContentStrategy::HashtagEngine.generate(
        photo: post.photo, pillar: post.photo&.content_pillar, count: HASHTAG_COUNT
      )

      # An empty result is NOT a repair: writing '[]' over '[]' would report a
      # success the board then believes. Leave the row alone and say so.
      if Array(tags).empty?
        return Result.new(post_id: post.id, outcome: :unfilled, hashtags: [],
                          error: 'hashtag engine returned no tags')
      end

      return Result.new(post_id: post.id, outcome: :would_fill, hashtags: tags) if dry_run

      post.update!(hashtags: tags)
      Result.new(post_id: post.id, outcome: :filled, hashtags: tags)
    rescue StandardError => e
      # A repair must never be able to break the queue: an untagged post is still
      # publishable, so an error here leaves the post exactly as it was.
      Result.new(post_id: post.id, outcome: :failed, hashtags: [],
                 error: "#{e.class}: #{e.message}")
    end
  end
end
