# frozen_string_literal: true

module Photos
  # Get available (unposted) photos with attached images for a persona.
  #
  # This is the pipeline's own selector -- the spend paths (`Growth::LibraryFallback`),
  # the legacy content strategies and the admin grid all read their candidates through
  # it, so a candidate pool that exists in the corpus but cannot be listed here is a
  # pool nothing can spend.
  class ListAvailable < ApplicationCommand
    requires persona: Persona
    allows pillar_id: Integer, low_quality_last: [ TrueClass, FalseClass ]

    returns :photos

    def call
      # Get photos not used in any posts for this persona
      # Note: Can't use .joins(:image_attachment) due to old records with different record_type
      #
      # `with_photo` on the subquery is LOAD-BEARING, not tidiness: a post may
      # legitimately carry NO photo (the REELS arm posts one -- see
      # Scheduling::Post's photo-presence validation), and `id NOT IN (..., NULL)` is
      # UNKNOWN for EVERY row in SQL -- so a single photo-less post emptied this entire
      # selector. Measured 2026-10-21 on the live DB: one reel post with a NULL photo_id
      # (created 2026-10-12) made this return 0 candidates while 43 servable unposted
      # photos existed, which silently killed `Growth::LibraryFallback` (the GPU-free
      # reserve -- its last spend was 2026-10-03), the admin photo grid and
      # `bin/library_depth.py`. The same guard already exists at `ContentStrategy::Context`
      # (content_strategy/context.rb:35); this is the primary selector and it was missing.
      all_photos = ContentPillars::Photo
        .where(persona_id: persona.id)
        .where.not(id: Scheduling::Post.where(persona_id: persona.id).with_photo.select(:photo_id))

      # Filter by pillar if specified
      all_photos = all_photos.where(content_pillar_id: pillar_id) if pillar_id.present?

      all_photos = rank_by_quality(all_photos)

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

    private

    # PRD 0007 B3: the realism measurement is ADVISORY, so its thresholds are
    # SELECTION defaults -- they ORDER the pool, they never filter it. An asset
    # below the aesthetic (4.5) or sharpness (30.0) default is ranked LAST and
    # stays fully listed and spendable, because the founder's ruling keeps
    # assets that crossed the border for re-valuation ("we can keep assets that we
    # think crossed the border for re-valuation at a later time"). Nothing is
    # purged, hidden or vetoed here; a purge is exactly what B3 removed.
    #
    # OVERRIDABLE, two ways: `low_quality_last: false` restores pure recency for a
    # caller that wants the raw order (a diff, a report, a grid a human is
    # auditing), and the thresholds themselves come from `Growth::RealismGate` --
    # the instrument that measures them -- so the ENV knobs (AESTHETIC_THRESHOLD /
    # SHARPNESS_THRESHOLD) move the gate's `flagged` verdict and this ordering
    # together instead of drifting apart.
    #
    # UNMEASURED (NULL) is NOT low quality: a photo the scorer never touched keeps
    # its recency position. That is load-bearing here -- the reserve IS the legacy
    # library, which mostly predates the gate stack, so ranking NULLs as bad would
    # silently disable the GPU-free fallback on the exact photos it exists to
    # spend. NULL-as-unmeasured, never NULL-as-verdict, is the same rule as
    # `photos.synthetic` and `photos.nsfw_score`.
    def rank_by_quality(relation)
      return relation.order(created_at: :desc) unless low_quality_last?

      relation.order(Arel.sql(low_quality_last_sql), created_at: :desc)
    end

    # The default is ON; only an explicit `low_quality_last: false` turns it off.
    def low_quality_last?
      low_quality_last.nil? ? true : low_quality_last
    end

    def low_quality_last_sql
      <<~SQL.squish
        CASE WHEN (aesthetic_score IS NOT NULL
                   AND aesthetic_score < #{Growth::RealismGate.aesthetic_threshold})
               OR (sharpness IS NOT NULL
                   AND sharpness < #{Growth::RealismGate.sharpness_threshold})
             THEN 1 ELSE 0 END
      SQL
    end
  end
end
