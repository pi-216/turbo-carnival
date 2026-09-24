# frozen_string_literal: true

module Scheduling
  class Post < ApplicationRecord
    self.table_name = 'scheduling_posts'

    belongs_to :photo, class_name: 'ContentPillars::Photo', optional: true
    belongs_to :persona, class_name: 'Persona'
    belongs_to :content_suggestion, optional: true
    belongs_to :pipeline_run, optional: true

    # A still post ready to publish must have its photo. EXCEPT a REELS post,
    # which has no photo to require: its published media
    # is the composed video at `reel_path`, built from SEVERAL renders, so there
    # is no single photo that "is" this post. Requiring one would either consume a
    # render (the (photo_id, persona_id) unique index then bars it from ever being
    # a still post -- a real cost of one image per reel) or misreport which asset
    # was published. Deliberate and load-bearing: it also keeps reels OUT of
    # Growth::GateRead#cohort_size, which counts posts that JOIN a photo, so the
    # pre-registered strategy cohort stays the still-based measurement it was
    # registered as while the discovery arm runs beside it.
    validates :photo, presence: true, if: -> { ready_to_post? && !reel? }

    # A photo is posted at most ONCE per persona. This is load-bearing, not
    # tidiness: Growth::LibraryFallback#spend and Growth::RenderSalvage use "a
    # Post row for this photo exists" as their idempotency MARKER, and they are
    # driven by three independent callers (bin/scheduled_posting.sh hourly,
    # Growth::AbandonedRenderWorker every 5 min, Growth::CadenceEngine#sync) --
    # two of which fire on the same trigger and the same candidate list, so a
    # check-then-act `exists?` alone lets an interleaved pair double-post the
    # same image. The DB-level guarantee is the unique index added in
    # 20260923233500; this validation only turns the violation into a friendly
    # error on the human-facing scheduling path. allow_nil keeps
    # `awaiting_image` drafts (photo_id NULL) unrestricted.
    validates :photo_id, uniqueness: { scope: :persona_id }, allow_nil: true

    scope :posted, -> { where(status: 'posted') }
    scope :with_strategy, ->(strategy_name) { where(strategy_name: strategy_name) }
    scope :awaiting_photo, -> { where(photo_id: nil) }
    scope :with_photo, -> { where.not(photo_id: nil) }
    # A post the platform actually published: Instagram returned a media id,
    # which UpdatePostWithInstagramId persists as provider_post_id. The
    # discriminator matters because scheduling_posts also holds rows written
    # straight into the table (test fixtures) -- measured 2026-09-22, 65 rows
    # with caption 'test', provider_post_id NULL and reach pinned at 1000,
    # carrying 2181 of the account's apparent likes and inflating EVERY
    # aggregate that filters on a bare `status: 'posted'`. Any count of what
    # the account actually did must go through this scope.
    scope :published_to_platform, -> { where.not(provider_post_id: nil) }

    state_machine :status, initial: :draft do
      state :draft           # Created, may or may not have image yet
      state :awaiting_image  # PipelineRun in progress
      state :ready           # Image linked, ready to schedule
      state :scheduled       # Scheduled for future posting
      state :posting         # Currently posting
      state :posted          # Successfully posted
      state :failed          # Posting failed

      event :start_image_generation do
        transition draft: :awaiting_image
      end

      event :image_ready do
        transition awaiting_image: :ready
      end

      event :schedule do
        transition [ :draft, :ready ] => :scheduled
      end

      event :start_posting do
        transition [ :draft, :scheduled ] => :posting
      end

      event :mark_as_posted do
        transition %i[scheduled posting] => :posted
      end

      event :mark_as_failed do
        transition %i[scheduled posting] => :failed
      end
    end

    def ready_to_post?
      %w[scheduled posting posted].include?(status)
    end

    # Transition to :failed AND persist why.
    #
    # The publisher used to call mark_as_failed! with no argument, so a rejected
    # post stored no reason at all: the cause (e.g. Instagram 400 code 9007
    # "media not ready for publishing", a container-readiness race) survived only
    # as a line in log/scheduled_posting.log. That made the ops board's
    # silent-failure detector (bin/tc_ops.py check_publish_failed_silent) able to
    # say a slot was lost but never why, and left the retry decision with no data
    # behind it. Truncated because the reason is an upstream API message, not a
    # document.
    FAILURE_REASON_MAX = 500

    def record_failure!(reason)
      mark_as_failed!
      update_columns(failure_reason: reason.to_s.strip.truncate(FAILURE_REASON_MAX))
    end

    def image_promise_fulfilled?
      photo_id.present?
    end

    # Is this post published as a REEL (motion) rather than a still?
    #
    # The discriminator is the presence of `reel_path`, and that is deliberate: a
    # still post and a REELS post differ on the API only by the container type,
    # and the asset path is what decides which container is even possible. A NULL
    # reel_path keeps every pre-existing row meaning exactly "still".
    def reel?
      reel_path.present?
    end
  end
end
