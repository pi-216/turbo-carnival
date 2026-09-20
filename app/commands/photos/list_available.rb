# frozen_string_literal: true

module Photos
  # Get available (unposted) photos with attached images for a persona
  class ListAvailable < GLCommand::Callable
    requires persona: Persona
    allows pillar_id: Integer

    returns :photos

    def call
      # Get photos not used in any posts for this persona
      # Note: Can't use .joins(:image_attachment) due to old records with different record_type
      all_photos = ContentPillars::Photo
        .where(persona_id: persona.id)
        .where.not(id: Scheduling::Post.where(persona_id: persona.id).select(:photo_id))
        .order(created_at: :desc)

      # Filter by pillar if specified
      all_photos = all_photos.where(content_pillar_id: pillar_id) if pillar_id.present?
      
      # Filter to photos whose bytes we can actually SERVE at publish time.
      #
      # This used to be `photo.image.attached?`, which was a proxy for "we have
      # bytes" and stopped holding when the local ComfyUI mounts moved. Measured
      # 2026-09-20: 168 of 336 photos have no bytes anywhere -- not at `path`, not
      # in the NAS fallback (NAS_OUTPUT_BASE points at a tree that does not
      # exist), not in ActiveStorage (all 101 attached-but-local-dead photos have
      # a missing blob file too). The old predicate failed in both directions:
      # it offered dead photos that can only fail later, at publish time (58 of 64
      # historical post failures reference a photo whose bytes are gone), and it
      # hid 23 servable renders that carry no ActiveStorage record at all.
      #
      # `servable_bytes?` is the model's byte-level answer for both sources, in
      # the publish path's precedence (local file, then ActiveStorage).
      context.photos = all_photos.select(&:servable_bytes?)
    end
  end
end
