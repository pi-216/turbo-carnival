# frozen_string_literal: true

module ContentPillars
  class LinkWinnerToPillar
    def self.call(run)
      new(run).call
    end

    def initialize(run)
      @run = run
    end

    def call
      return unless should_link?

      winner = find_winner
      return unless winner

      create_photo(winner)
    end

    private

    def should_link?
      unless @run.content_pillar_id.present?
        Rails.logger.debug("Run #{@run.id} has no pillar, skipping auto-linking")
        return false
      end

      true
    end

    def find_winner
      winner = @run.image_candidates.find_by(winner: true)

      unless winner
        Rails.logger.warn("Run #{@run.id} completed but has no winner")
      end

      winner
    end

    def create_photo(winner)
      photo = ContentPillars::CreatePhotoFromCandidate.call(winner, @run.content_pillar)

      if photo
        Rails.logger.info("Auto-linked winner #{winner.id} to pillar #{@run.content_pillar.name} (photo #{photo.id})")
        photo
      else
        Rails.logger.error("Failed to create photo from winner #{winner.id}")
        nil
      end
    end
  end
end
