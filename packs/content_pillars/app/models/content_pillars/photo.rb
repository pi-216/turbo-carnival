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

    # Roots that mirror the ComfyUI output tree. The render mount has moved
    # (an original /mnt/essdee/ComfyUI, then /mnt/fscache/essdee/ComfyUI, which
    # is itself a symlink into the NAS), so a photo's `path` records WHICH MOUNT
    # WAS CURRENT when it was imported -- not where its bytes live now. Resolving
    # a photo therefore means stripping a known ComfyUI-output prefix and
    # retrying under every root that exists.
    #
    # This replaced NAS_OUTPUT_BASE
    # ('/mnt/synology-home/backup/essdee/ComfyUI'), which is not a mount at all
    # (/mnt/synology-home is an empty directory) -- so the fallback silently
    # returned nil for every photo whose mount had moved. Measured 2026-09-20:
    # 101 photos read as "no bytes anywhere" while their bytes sat intact at the
    # same RELATIVE path under /mnt/nas-ai-models/comfyui-output. A resolution
    # root that does not exist is a silent dead end, so roots are kept to real
    # mounts and `tc_ops.py check_photo_source_roots` asserts they exist.
    MIRROR_ROOTS = [
      ENV['COMFYUI_MIRROR_ROOT'],
      '/mnt/nas-ai-models/comfyui-output'
    ].compact.freeze

    # Every mount prefix the ComfyUI output tree has been served from.
    OUTPUT_PREFIX = %r{\A/mnt/(?:fscache/)?essdee/ComfyUI/(?:output/)?}

    # Resolve a readable, local file path for this photo's image bytes,
    # without touching ActiveStorage/B2. Returns nil when no source exists.
    def servable_file_path
      direct = path.to_s
      return direct if direct.present? && File.file?(direct)

      if direct.match?(OUTPUT_PREFIX)
        rel = direct.sub(OUTPUT_PREFIX, '')
        MIRROR_ROOTS.each do |root|
          [File.join(root, rel), File.join(root, 'output', rel)].each do |cand|
            return cand if File.file?(cand)
          end
        end
      end

      # A bare filename carries no relative path, so its identity cannot be
      # established: the mirror holds thousands of files sharing generic names
      # (image_00002_.png), and a first-match glob can serve a DIFFERENT photo's
      # bytes. Unresolvable by name, so deliberately nil.
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
