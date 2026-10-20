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
          [ File.join(root, rel), File.join(root, 'output', rel) ].each do |cand|
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

    # The ONE place a completed render becomes a Photo, so the synthetic mark
    # cannot be remembered by one producer and forgotten by the other.
    # Growth::ContentGenerator (sync) and Growth::RenderSalvage (recovery) each
    # used to create the row themselves -- and RenderSalvage exists precisely
    # because the sync path can die mid-render, so anything the row must carry
    # has to live at a single choke point.
    #
    # `synthetic: true` is written explicitly (never defaulted) and `provenance`
    # records what is known about the render. Since tasks 2.1/2.2 of the same
    # change, the mark is also written INTO the asset here -- at the same choke
    # point, so the file Meta will fetch is marked before any post can reference
    # it -- and `provenance.embedded` is set from that write's result, not from
    # the intent to make it.
    #
    # The NSFW MEASUREMENT rides the same choke point (PRD 0007 A1): `nsfw_score` /
    # `nsfw_flagged` come from Growth::NsfwGate's result, passed as primitives
    # because this pack must not depend upward on the growth pack. Both producers
    # (Growth::ContentGenerator and Growth::RenderSalvage) go through here, so a
    # producer that forgets the score cannot leave an asset with no measurement
    # recorded -- and on the idempotent path (a render whose row already exists,
    # which is exactly the interrupted-producer case RenderSalvage exists for) the
    # score is BACKFILLED rather than dropped.
    def self.import_render(path:, persona:, content_pillar:, run: nil, nsfw_score: nil, nsfw_flagged: nil)
      existing = find_by(path: path)
      return existing.record_nsfw_score(nsfw_score: nsfw_score, nsfw_flagged: nsfw_flagged) if existing

      created = create!(
        persona: persona,
        path: path,
        content_pillar: content_pillar,
        image_candidate: nil,
        synthetic: true,
        nsfw_score: nsfw_score,
        nsfw_flagged: nsfw_flagged,
        provenance: PhotoProvenance.mark_asset(PhotoProvenance.for_run(run), path)
      )
      created
    rescue ActiveRecord::RecordInvalid
      find_by(path: path)&.record_nsfw_score(nsfw_score: nsfw_score, nsfw_flagged: nsfw_flagged)
    end

    # Record a measured NSFW score on this asset (PRD 0007 A1). Used by the import
    # choke point and by Growth::LibraryFallback, which re-measures library photos it
    # is about to spend.
    #
    # A MEASUREMENT IS FILLED IN, NEVER CLOBBERED: a row that already carries a score
    # keeps it, because the stored flag is the verdict OF RECORD at the threshold then
    # in force. Re-scoring an asset under a revised threshold is an explicit act
    # (the re-valuation the founder's ruling refers to), not a side effect of an
    # import or a spend. A nil score writes nothing: NULL means unmeasured, and an
    # unmeasured pass must not look like a measurement.
    def record_nsfw_score(nsfw_score:, nsfw_flagged: nil)
      return self if nsfw_score.nil? || self.nsfw_score.present?

      update_columns(nsfw_score: nsfw_score, nsfw_flagged: nsfw_flagged)
      self
    end

    # Mark this photo's own asset bytes, on demand. Used by the publish gate for
    # photos that predate the creation-time mark, and by `photos:embed_provenance`
    # for the corpus. Returns the marker's verdict (:marked / :already_marked /
    # :missing / :unsupported / :error).
    def mark_synthetic_asset!
      file = servable_file_path
      return :missing if file.blank?

      result = ContentPillars::PhotoAssetMarker.mark!(file, provenance || {})

      if %i[marked already_marked].include?(result)
        update_columns(provenance: PhotoProvenance.mark_asset(provenance || {}, file),
                       synthetic: true)
      end

      result
    end

    def posted?
      # Will be true when scheduling pack exists
      # For now, always false
      false
    end
  end
end
