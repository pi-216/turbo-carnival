# frozen_string_literal: true

module ContentPillars
  class Photo < ApplicationRecord
    self.table_name = 'photos'

    has_one_attached :image

    belongs_to :persona
    belongs_to :content_pillar, class_name: 'ContentPillar'
    belongs_to :image_candidate, class_name: 'ImageCandidate', optional: true

    validates :path, presence: true, uniqueness: true
    validates :persona, presence: true

    scope :unposted, -> {
      where.not(id: select(:id).where('EXISTS (SELECT 1 FROM scheduling_posts WHERE photo_id = photos.id)'))
    }

    # Root of the NAS backup tree that mirrors the original ComfyUI output
    # mount (/mnt/essdee/ComfyUI). Used to serve photo files without B2.
    NAS_OUTPUT_BASE = '/mnt/synology-home/backup/essdee/ComfyUI'

    # Resolve a readable, local file path for this photo's image bytes,
    # without touching ActiveStorage/B2. Returns nil when no source exists.
    def servable_file_path
      direct = path.to_s
      return direct if direct.present? && File.file?(direct)

      if direct.start_with?('/mnt/essdee/ComfyUI/')
        rel = direct.sub(%r{^/mnt/essdee/ComfyUI/}, '')
        [File.join(NAS_OUTPUT_BASE, rel),
         File.join(NAS_OUTPUT_BASE, 'output', rel)].each do |cand|
          return cand if File.file?(cand)
        end
      end

      # Bare filename (no mount prefix) → bounded search of the NAS tree
      if direct == File.basename(direct)
        found = Dir.glob("#{NAS_OUTPUT_BASE}/output/**/#{direct}").first
        return found if found
      end

      nil
    end

    def servable?
      servable_file_path.present?
    end

    # Does this photo have BYTES we can serve, by either source the publish path
    # knows? `image.attached?` is a RECORD that once pointed at bytes, not
    # evidence they are still there: measured 2026-09-20, all 101 attached photos
    # whose local file is gone also have a missing blob file on the :local Disk
    # service (storage/ holds 116K in total). Anything selecting candidates on
    # `attached?` alone therefore offers photos that can only fail at publish
    # time. Local file first, ActiveStorage second -- the same precedence as
    # Scheduling::Commands::GeneratePublicPhotoUrl.
    def servable_bytes?
      return true if servable?
      return false unless image.attached?

      blob = image.blob
      blob.present? && blob.service.exist?(blob.key)
    rescue StandardError
      false
    end

    def posted?
      # Will be true when scheduling pack exists
      # For now, always false
      false
    end
  end
end
