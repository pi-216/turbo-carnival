# frozen_string_literal: true

require 'json'
require 'open3'
require 'tmpdir'

module Growth
  # Pre-publish NEAR-DUPLICATE GATE: hold a queued post whose image is (nearly)
  # the same as something already published, or as another queued post.
  #
  # WHY THIS EXISTS (root cause, 2026-09-24): Instagram removed 36 of the 150
  # posts this account published, and the removals are CONTENT-linked, not
  # publish-slot-linked. Measured read-only with dHash (9x8 grey, 64-bit) over
  # every published asset still on disk plus every queued asset:
  #
  #   * posts 138-142 published the SAME image on five consecutive days
  #     (dHash distance 0, all five from one collapsed render directory
  #     auto-wellness-self-care-20260526), and ALL FIVE were removed;
  #   * every pair at distance <= 6 in the whole corpus is inside the removed
  #     set (11 pairs), and NO surviving pair is closer than distance 7;
  #   * `grep -rniE 'dhash|phash|perceptual|near-dup' packs/ bin/ app/ lib/`
  #     found no such check anywhere -- so the only thing standing between a
  #     collapsed render batch and a duplicate post was nothing.
  #
  # Instagram suppresses duplicate content, so this is both a removal cause and
  # an independent candidate contributor to the account's ~0 reach. The gate is
  # the fix for the removal cause; the reach question is measured separately by
  # Growth::GateRead.
  #
  # TWO POPULATIONS, deliberately. Comparing a candidate only against the
  # PUBLISHED corpus catches the second and later copies of a collapsed batch --
  # the first copy still ships. Comparing it against the QUEUE as well catches
  # the batch before any of it ships: of N queued posts carrying the same image,
  # exactly one (the earliest slot) is kept and the rest are held. Both legs use
  # the same threshold and the same hasher.
  #
  # WHAT IT DOES: for each unpublished post with a future slot, hash its render
  # (bin/dhash.py -- Ruby has no PNG decoder in this bundle) and compare it with
  # every already-published asset and every other queued asset. A match within
  # NEAR_DUP_THRESHOLD (default 6 -- the measured boundary: removed set reaches
  # 6, surviving set starts at 7) HOLDS the post by clearing BOTH of the
  # publisher's clocks (scheduled_at and optimal_time_calculated), records the
  # match on the row, and writes a Growth::Decision. That is the same hold
  # mechanism Growth::PersonaAgeGate uses, and for the same reason: status is not
  # touched because `scheduling:post_scheduled` selects a due post as
  # `status=scheduled AND scheduled_at <= now` OR `status=draft AND
  # optimal_time_calculated <= now`, so a post with neither clock is never
  # released, the row's history stays intact and the write is trivially
  # reversible (both cleared clocks are recorded in the Decision's reason).
  #
  # Holding also feeds the queue with no extra machinery: the cadence engine
  # counts queued posts by the same two clocks, so a held post drops out of the
  # count, the shortfall reopens, and the next growth tick renders a REPLACEMENT.
  # Hold the duplicate, render something else -- not a stalled slot.
  #
  # DIRECTION OF ERROR, deliberately chosen: the gate FAILS OPEN. An unreadable
  # render (missing bytes, undecodable, hasher unavailable) records nothing and
  # publishes exactly as it did before the gate existed, so the gate can never
  # make the queue worse than it already is. The cost of the other direction is
  # paid too often to guess at: a false hold discards a paid-for render.
  #
  # NOT COVERED, stated so nobody re-derives it: the removed assets' bytes are
  # gone from disk (36 removed, only the survivors are hashable), so a candidate
  # that duplicates a REMOVED post cannot be caught by this gate -- the corpus is
  # what is still on disk. That is a smaller exposure than it looks (a collapsed
  # batch puts its copies in the queue together, which the queue leg catches) but
  # it is not zero.
  #
  # DRY-RUN BY DEFAULT (same contract as Growth::PersonaAgeGate and
  # ContentStrategy::QueuedHashtagBackfill): the write path is opt-in with
  # APPLY=1 via rake, or dry_run: false.
  class NearDuplicateGate
    UNPUBLISHED_STATUSES = %w[draft scheduled].freeze
    DEFAULT_LIMIT = 3
    # The measured boundary, not a round number: over the 2026-09-24 corpus every
    # pair at dHash distance <= 6 sits inside Instagram's removed set, and no
    # surviving pair is closer than 7. Overridable per call or with
    # NEAR_DUP_THRESHOLD for a re-measurement.
    DEFAULT_THRESHOLD = 6
    # Marker key in scheduling_posts.caption_metadata, mirroring
    # Growth::PersonaAgeGate::METADATA_KEY: a post that has been read is not
    # re-read, and a held post carries the match that held it as its audit trail.
    METADATA_KEY = 'near_dup_gate'
    CACHE_VERSION = 1

    ENTRY_PUBLISHED = :published
    ENTRY_QUEUED = :queued

    # One hashable asset in the comparison set: a published post's render, or a
    # queued post's render (the candidate itself is one of these).
    Entry = Struct.new(:kind, :photo, :hash, :post, keyword_init: true)

    Result = Struct.new(:post_id, :photo_id, :verdict, :distance, :partner_kind,
                        :partner_post_id, :partner_photo_id, :outcome, :error,
                        keyword_init: true)

    # dHash over the images, via bin/dhash.py. Ruby has no PNG decoder in this
    # bundle, and the ComfyUI venv already carries PIL.
    #
    # One process for the WHOLE batch (a tick hashes ~170 assets, so a process
    # per image would dominate the runtime), and an undecodable path is reported
    # per line rather than aborting: the gate fails open.
    class Hasher
      TIMEOUT = 180

      def self.call(paths)
        paths = Array(paths).compact.uniq
        return {} if paths.empty?

        script = Rails.root.join('bin', 'dhash.py')
        unless File.file?(script)
          Rails.logger.error("Growth::NearDuplicateGate::Hasher: #{script} is missing — no hashes")
          return {}
        end

        Dir.mktmpdir('dhash', Rails.root.join('tmp').to_s) do |dir|
          list = File.join(dir, 'paths.txt')
          File.write(list, paths.join("\n"))
          out, err, status = Open3.capture3(python, script.to_s, '--paths-file', list)
          unless status.success?
            Rails.logger.error("Growth::NearDuplicateGate::Hasher: #{python} exited " \
                               "#{status.exitstatus}: #{err.to_s.truncate(300)}")
            return {}
          end
          parse(out)
        end
      rescue StandardError => e
        Rails.logger.error("Growth::NearDuplicateGate::Hasher: #{e.class} - #{e.message}")
        {}
      end

      def self.python
        ENV['DHASH_PYTHON'].presence || '/mnt/fscache/essdee/ComfyUI/venv/bin/python'
      end

      def self.parse(out)
        out.to_s.each_line.with_object({}) do |line, acc|
          line = line.strip
          next if line.empty?

          row = begin
            JSON.parse(line)
          rescue JSON::ParserError
            next
          end
          bits = row['dhash']
          next unless bits.is_a?(String) && row['path'].present?

          acc[row['path']] = bits.to_i(16)
        end
      end
    end

    def self.call(persona:, dry_run: true, limit: DEFAULT_LIMIT, threshold: nil,
                  now: Time.current, hash_source: nil, cache: nil, cache_path: nil)
      new(persona: persona, now: now, threshold: threshold, hash_source: hash_source,
          cache: cache, cache_path: cache_path).call(dry_run: dry_run, limit: limit)
    end

    def initialize(persona:, now: Time.current, threshold: nil, hash_source: nil, cache: nil,
                   cache_path: nil)
      @persona = persona
      @now = now
      @threshold = (threshold || ENV['NEAR_DUP_THRESHOLD'].presence || DEFAULT_THRESHOLD).to_i
      @hash_source = hash_source || Hasher
      # nil means "the default": enabled in production, disabled in specs.
      @cache = cache.nil? ? true : cache
      @cache_path = cache_path
    end

    def call(dry_run: true, limit: DEFAULT_LIMIT)
      ordered = queued_posts
      published = corpus_posts

      # The comparison set's SIZE is part of the read's validity: a verdict
      # recorded against a 150-asset corpus and a 21-post queue does not stand
      # once either has moved, because a newly PUBLISHED image can make an
      # already-cleared render a duplicate. Recording the sizes keeps the
      # idempotency (and the advancing "nearest slot first" window) without
      # letting a stale read outlive the set it was made against.
      @corpus_size = published.count { |post| asset_path(post.photo) }
      @queue_size = ordered.size

      targets = ordered.reject { |post| already_read?(post) }.first(limit)
      return [] if targets.empty?

      # Only the posts up to the LAST target need a hash: the queue leg compares
      # each candidate against everything that could precede it, and nothing
      # later than the last target can precede it. That keeps a tick hashing the
      # corpus plus a handful of queue assets rather than the whole queue.
      last_index = ordered.index(targets.last)
      considered = ordered[0..last_index]

      entries, unreadable = build_entries(published, considered)

      if unreadable.any?
        Rails.logger.warn("Growth::NearDuplicateGate: #{unreadable.size} queued render(s) " \
                          'unreadable (no hash) — publishing as before: ' \
                          "#{unreadable.first(3).map(&:id).inspect}")
      end

      entry_by_post = entries.select { |e| e.kind == ENTRY_QUEUED }.to_h { |e| [ e.post.id, e ] }

      targets.filter_map { |post| entry_by_post[post.id] }
             .map { |entry| check(entry, entries, dry_run: dry_run) }
    end

    # Unpublished posts with a FUTURE slot, nearest slot first. Nearest-first
    # matters twice: the publisher runs this hourly with a small limit, so the
    # posts that publish soonest are checked first, and the queue leg's
    # "keep the earliest, hold the rest" rule needs the whole queue in view.
    def queued_posts
      Scheduling::Post
        .where(persona: @persona, status: UNPUBLISHED_STATUSES)
        .where.not(photo_id: nil)
        .where('scheduled_at > ? OR optimal_time_calculated > ?', @now, @now)
        .order(Arel.sql('COALESCE(scheduled_at, optimal_time_calculated) ASC'))
        .to_a
    end

    # Every post that reached Instagram, whose bytes are still on disk. This is
    # the corpus the platform itself has seen (minus the removed assets whose
    # bytes were deleted -- see the class comment).
    def corpus_posts
      Scheduling::Post
        .where(persona: @persona)
        .where.not(provider_post_id: nil)
        .where.not(photo_id: nil)
        .includes(:photo)
        .to_a
        .reject { |post| asset_path(post.photo).nil? }
    end

    private

    def build_entries(published, queue_posts)
      paths = published.map { |post| asset_path(post.photo) } +
              queue_posts.map { |post| asset_path(post.photo) }
      paths = paths.compact.uniq
      hashes = hashes_for(paths)

      entries = []
      unreadable = []

      published.each do |post|
        next if post.photo.nil?

        bits = hashes[asset_path(post.photo)]
        next if bits.nil?

        entries << Entry.new(kind: ENTRY_PUBLISHED, photo: post.photo, hash: bits, post: post)
      end

      queue_posts.each do |post|
        bits = hashes[asset_path(post.photo)]
        if bits.nil?
          unreadable << post
          next
        end

        entries << Entry.new(kind: ENTRY_QUEUED, photo: post.photo, hash: bits, post: post)
      end

      [ entries, unreadable ]
    end

    def check(entry, entries, dry_run:)
      analysis = analyse(entry, entries)
      nearest = analysis[:nearest]
      blockers = analysis[:blockers]

      if blockers.any?
        blocker = blockers.first
        return result(entry, :duplicate, blocker, :would_hold) if dry_run

        hold(entry.post, blocker)
        result(entry, :duplicate, blocker, :held)
      elsif nearest && nearest[:distance] <= @threshold
        # A twin that does NOT precede us: we are the earliest of the pair, so we
        # publish and the twin is held on its own turn. Recorded so the tick does
        # not re-hash and re-decide this post.
        entry.post.update_columns(caption_metadata: write_metadata(entry.post, nearest, :kept_earliest, held: false)) unless dry_run
        result(entry, :kept_earliest, nearest, dry_run ? :would_keep : :kept)
      else
        entry.post.update_columns(caption_metadata: write_metadata(entry.post, nearest, :distinct, held: false)) unless dry_run
        result(entry, :distinct, nearest, dry_run ? :would_clear : :cleared)
      end
    end

    # Nearest neighbour overall, and the subset that BLOCKS publication.
    #
    # A neighbour blocks when it is published (a copy of something public has no
    # business shipping) or when it is another queued post that sorts EARLIER by
    # (slot, id) -- the deterministic tie-break that keeps exactly one member of a
    # collapsed batch: the earliest slot, lowest id.
    def analyse(entry, entries)
      scored = entries
               .reject { |other| other.kind == ENTRY_QUEUED && other.post&.id == entry.post.id }
               .map { |other| { distance: hamming(entry.hash, other.hash), entry: other } }
               .sort_by { |s| [ s[:distance], sort_key(s[:entry]) ] }

      blockers = scored.select do |s|
        s[:distance] <= @threshold &&
          (s[:entry].kind == ENTRY_PUBLISHED || precedes?(s[:entry].post, entry.post))
      end

      { nearest: scored.first, blockers: blockers }
    end

    def sort_key(entry)
      [
        entry.kind == ENTRY_PUBLISHED ? 0 : 1,
        slot_time(entry.post).to_f,
        entry.post&.id || 0
      ]
    end

    def precedes?(a, b)
      return false if a.nil? || b.nil?

      ta = slot_time(a).to_f
      tb = slot_time(b).to_f
      return true if ta < tb
      return false if ta > tb

      a.id < b.id
    end

    def slot_time(post)
      post.scheduled_at || post.optimal_time_calculated || Time.at(0)
    end

    def hamming(a, b)
      (a ^ b).to_s(2).count('1')
    end

    def hold(post, blocker)
      before = { scheduled_at: post.scheduled_at, optimal_time_calculated: post.optimal_time_calculated }
      post.update_columns(
        scheduled_at: nil,
        optimal_time_calculated: nil,
        caption_metadata: write_metadata(post, blocker, :duplicate, held: true)
      )
      Rails.logger.warn("Growth::NearDuplicateGate: HELD post #{post.id} (photo #{post.photo_id}, " \
                        "slot #{before[:scheduled_at] || before[:optimal_time_calculated]}) — " \
                        "#{describe(blocker)} at dHash distance #{blocker[:distance]}, kept the earlier copy")
      Growth::Decision.create!(
        goal: goal,
        action: 'near_dup_hold',
        reason: "near-duplicate render (#{describe(blocker)}, dHash distance " \
                "#{blocker[:distance]} <= #{@threshold}); held post #{post.id} " \
                "(photo #{post.photo_id}) from slot #{before[:scheduled_at] || before[:optimal_time_calculated]}",
        decided_at: Time.current
      ) if goal
    rescue StandardError => e
      # A hold that fails must be LOUD: the duplicate is still publishable.
      Rails.logger.error("Growth::NearDuplicateGate: could not hold post #{post.id}: #{e.class} - #{e.message}")
      raise
    end

    def describe(nearest)
      e = nearest[:entry]
      if e.kind == ENTRY_PUBLISHED
        "published post #{e.post&.id} (photo #{e.photo.id})"
      else
        "queued post #{e.post&.id} (photo #{e.photo.id})"
      end
    end

    # Merge, never replace: caption_metadata carries the caption's own provenance
    # (and the age gate's own read) and must survive a gate write.
    def write_metadata(post, nearest, verdict, held:)
      meta = post.caption_metadata.is_a?(Hash) ? post.caption_metadata.dup : {}
      other = nearest && nearest[:entry]
      meta[METADATA_KEY] = {
        'verdict' => verdict.to_s,
        'distance' => nearest && nearest[:distance],
        'threshold' => @threshold,
        'algorithm' => 'dhash9x8',
        'partner_kind' => other&.kind&.to_s,
        'partner_post_id' => other&.post&.id,
        'partner_photo_id' => other&.photo&.id,
        'checked_at' => Time.current.utc.iso8601,
        'held' => held,
        # The set the read was made against; a later tick re-decides if it moved.
        'corpus_size' => @corpus_size,
        'queue_size' => @queue_size
      }
      meta
    end

    def already_read?(post)
      meta = post.caption_metadata
      return false unless meta.is_a?(Hash)

      gate = meta[METADATA_KEY]
      return false unless gate.is_a?(Hash)

      # Every verdict this gate can reach is a decision, so a recorded verdict is
      # never re-read -- UNLESS the comparison set has moved since, because the
      # corpus only grows and a newer published image can make a cleared render a
      # duplicate. An unreadable render records nothing and is retried anyway.
      return false unless %w[duplicate kept_earliest distinct].include?(gate['verdict'])

      gate['corpus_size'] == @corpus_size && gate['queue_size'] == @queue_size
    end

    def result(entry, verdict, nearest, outcome)
      Result.new(
        post_id: entry.post.id, photo_id: entry.post.photo_id, verdict: verdict,
        distance: nearest && nearest[:distance],
        partner_kind: nearest && nearest[:entry]&.kind,
        partner_post_id: nearest && nearest[:entry]&.post&.id,
        partner_photo_id: nearest && nearest[:entry]&.photo&.id,
        outcome: outcome
      )
    end

    def goal
      @goal ||= Growth::Goal.active.for_persona(@persona).first
    end

    def asset_path(photo)
      photo&.servable_file_path
    end

    # ---- hash cache ------------------------------------------------------
    # The published corpus is ~150 assets and re-hashing all of them every hour
    # on a shared box is pure waste. The cache is keyed by path and invalidated
    # by (size, mtime), which is what makes it safe: ContentPillars::
    # PhotoAssetMarker rewrites a published asset IN PLACE (temp file + atomic
    # rename), so both change and the entry is recomputed -- and because the mark
    # only adds metadata to the container, the PIXELS (and so the dHash) are
    # identical either way, so an invalidation costs a recompute, not a wrong
    # verdict.
    def hashes_for(paths)
      return @hash_source.call(paths) unless @cache

      cached = load_cache
      hits = {}
      missing = []

      paths.each do |path|
        entry = cached[path]
        if fresh_entry?(entry, path)
          hits[path] = entry['dhash'].to_i(16)
        else
          missing << path
        end
      end

      computed = @hash_source.call(missing)
      hits.merge!(computed)
      store_cache(paths, hits)
      hits
    end

    def cache_path
      @cache_path ||= Rails.root.join('log', 'near_dup_hashes.json')
    end

    def load_cache
      return {} unless File.file?(cache_path)

      doc = JSON.parse(File.read(cache_path))
      return {} unless doc.is_a?(Hash) && doc['version'] == CACHE_VERSION

      hashes = doc['hashes']
      hashes.is_a?(Hash) ? hashes : {}
    rescue StandardError => e
      Rails.logger.warn("Growth::NearDuplicateGate: unreadable hash cache (#{e.class}) — recomputing")
      {}
    end

    def fresh_entry?(entry, path)
      return false unless entry.is_a?(Hash) && entry['dhash'].is_a?(String)

      entry['size'] == file_size(path) && entry['mtime'] == file_mtime(path)
    end

    def file_size(path)
      File.size(path)
    rescue StandardError
      nil
    end

    def file_mtime(path)
      File.mtime(path).to_i
    rescue StandardError
      nil
    end

    def store_cache(paths, hashes)
      doc = {
        'version' => CACHE_VERSION,
        'updated_at' => Time.current.utc.iso8601,
        'hashes' => paths.each_with_object({}) do |path, acc|
          bits = hashes[path]
          next if bits.nil?

          acc[path] = { 'dhash' => format('%016x', bits), 'size' => file_size(path), 'mtime' => file_mtime(path) }
        end
      }
      tmp = "#{cache_path}.tmp"
      File.write(tmp, JSON.generate(doc))
      File.rename(tmp, cache_path)
    rescue StandardError => e
      Rails.logger.warn("Growth::NearDuplicateGate: could not write hash cache (#{e.class}) — continuing")
    end
  end
end
