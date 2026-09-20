# frozen_string_literal: true

module CaptionGeneration
  # Replace the placeholder caption on posts that have NOT published yet.
  #
  # Both growth-harness producers write the literal placeholder 'Fresh look ✨'
  # when the captioner fails (cold model, client timeout, service down) and the
  # post is then queued like any other. Nothing ever re-tried it: the caption
  # ladder fixed WHY the call failed, but the artifact the outage had already
  # written stayed in the queue and was published verbatim. Measured 2026-09-20:
  # 5 scheduled posts carried the placeholder, 4 of them due inside two hours,
  # while every caption probe read green (they measure the producer window, and
  # the newest post had a real caption).
  #
  # CaptionMetadata records that a post is a placeholder. This turns that record
  # into a repair, and it is the only place that knows the repair is safe: a post
  # that is still draft/scheduled and still in the future has not been sent, so
  # replacing its caption changes nothing that has already happened.
  #
  # DRY-RUN BY DEFAULT. Replacing a queued caption is a live-publishing edit --
  # it changes what the public account will say -- so the write path is opt-in
  # (APPLY=1 via rake, or dry_run: false) and never silent.
  class PlaceholderRefresh
    # The producers' exact placeholder; matching on the prefix keeps the door
    # open to a future variant ('Fresh look (fallback)') without a code change.
    PLACEHOLDER_PREFIX = 'Fresh look'
    UNPUBLISHED_STATUSES = %w[draft scheduled].freeze

    Result = Struct.new(:post_id, :outcome, :caption, :error, keyword_init: true)

    def self.call(dry_run: true, persona: nil, now: Time.current)
      new(persona: persona, now: now).call(dry_run: dry_run)
    end

    def initialize(persona: nil, now: Time.current)
      @persona = persona
      @now = now
    end

    # Unpublished posts whose stored caption is still the failure artifact, in
    # publish order. `optimal_time_calculated` is the publisher's other clock for
    # draft rows, so both are used -- the same predicate
    # scheduling:post_scheduled selects on.
    def candidates
      scope = Scheduling::Post.where(status: UNPUBLISHED_STATUSES)
      scope = scope.where(persona: @persona) if @persona
      scope.where('scheduled_at > ? OR optimal_time_calculated > ?', @now, @now)
           .where('caption LIKE ?', "#{PLACEHOLDER_PREFIX}%")
           .order(:scheduled_at)
    end

    def call(dry_run: true)
      candidates.map { |post| refresh(post, dry_run: dry_run) }
    end

    private

    def refresh(post, dry_run:)
      if dry_run
        return Result.new(post_id: post.id, outcome: :would_refresh, caption: post.caption)
      end

      result = PostAutomation::GenerateCaption.call(
        photo: post.photo, persona: post.persona, pillar: post.photo&.content_pillar
      )

      unless CaptionMetadata.success?(result)
        return Result.new(post_id: post.id, outcome: :failed, caption: post.caption,
                          error: CaptionMetadata.failure_message(result))
      end

      post.update!(caption: result.caption,
                   caption_metadata: CaptionMetadata.for_result(result))
      Result.new(post_id: post.id, outcome: :refreshed, caption: result.caption)
    rescue StandardError => e
      # A repair must never be able to break the queue: the placeholder is still
      # publishable, so an error here leaves the post exactly as it was.
      Result.new(post_id: post.id, outcome: :failed, caption: post.caption,
                 error: "#{e.class}: #{e.message}")
    end
  end
end
