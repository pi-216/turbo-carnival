# frozen_string_literal: true

module Attribution
  # The ONE writer for elo-picker taste verdicts into the attribution spine.
  #
  # Reads elo-picker on `sha256` (read-only) and records the rating as
  # `Attribution::Assessment` rows on every render that produced the asset. The assessor
  # is keyed (model + version) so elo-picker's numbers never collide with another
  # assessor's measurement of the same metric.
  #
  # FAIL-OPEN, NEVER A GATE: an absent rating, or an unreachable elo-picker, records
  # nothing and returns success -- elo-picker is never a blocker for posting. The
  # day-to-day path must complete unaffected whether a rating exists or not. This
  # command is the only surface that references elo-picker; the posting path never
  # calls it.
  #
  # A re-read REFRESHES the recorded value when elo-picker still holds a rating (its
  # numbers move as votes land); an absent re-read leaves the prior measurement alone --
  # a measurement that happened is not undone.
  class RecordEloRating < ApplicationCommand
    requires :sha256
    allows :asset, :reader

    returns :rating, :recorded

    ASSESSOR_MODEL = "elo-picker"
    ASSESSOR_VERSION = "images-v1"
    METRICS = %i[elo rd wins losses draws].freeze

    def call
      rating = read_rating
      context.rating = rating
      context.recorded = false

      return if rating.nil?

      asset = resolve_asset
      context.recorded = record(asset) if asset
    end

    private

    def read_rating
      return context.reader.rating_for(context.sha256) if context.reader

      EloPickerReader.rating_for(context.sha256)
    end

    def resolve_asset
      context.asset || Asset.for_sha256(context.sha256)
    end

    def record(asset)
      wrote = false
      asset.renders.find_each do |render|
        wrote = true
        METRICS.each do |metric|
          assessment = render.assessments.find_or_initialize_by(
            assessor_model: ASSESSOR_MODEL,
            assessor_version: ASSESSOR_VERSION,
            metric: metric.to_s
          )
          assessment.value = context.rating.public_send(metric)
          assessment.assessed_at = Time.current
          assessment.save!
        end
      end
      wrote
    end
  end
end
