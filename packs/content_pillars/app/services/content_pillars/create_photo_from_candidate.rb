# frozen_string_literal: true

module ContentPillars
  class CreatePhotoFromCandidate
    def self.call(candidate, pillar)
      new(candidate, pillar).call
    end

    def initialize(candidate, pillar)
      @candidate = candidate
      @pillar = pillar
    end

    def call
      return nil unless valid?

      create_photo
    rescue StandardError => e
      Rails.logger.error("Failed to create photo from candidate #{@candidate.id}: #{e.message}")
      nil
    end

    private

    def valid?
      unless @candidate
        Rails.logger.warn("No candidate provided")
        return false
      end

      unless @pillar
        Rails.logger.warn("No pillar provided")
        return false
      end

      unless File.exist?(@candidate.image_path)
        Rails.logger.warn("Image file not found: #{@candidate.image_path}")
        return false
      end

      true
    end

    def create_photo
      photo = ContentPillars::Photo.create!(
        persona: @pillar.persona,
        content_pillar: @pillar,
        path: @candidate.image_path,
        image_candidate: @candidate
      )

      attach_image(photo)

      Rails.logger.info("Created photo #{photo.id} from candidate #{@candidate.id}")
      photo
    end

    def attach_image(photo)
      photo.image.attach(
        io: File.open(@candidate.image_path),
        filename: File.basename(@candidate.image_path),
        content_type: content_type
      )
    end

    def content_type
      case File.extname(@candidate.image_path).downcase
      when '.png' then 'image/png'
      when '.jpg', '.jpeg' then 'image/jpeg'
      when '.webp' then 'image/webp'
      else 'image/png'
      end
    end
  end
end
