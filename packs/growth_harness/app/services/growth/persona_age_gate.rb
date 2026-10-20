# frozen_string_literal: true

module Growth
  # Pre-publish AGE GATE (PRD 0007 B1): hold a queued post whose render reads
  # as a minor, tier-aware.
  #
  # WHY THIS EXISTS (root cause, 2026-09-21): the account is adult-oriented and
  # nothing between a render and Instagram asked how old the person in the image
  # looks. Independent vision reads of production renders returned "a young girl,
  # likely a teenager" and "late teens or early twenties" repeatedly, stable
  # across a checkpoint change, and the newest read was on a render the pipeline
  # had already QUEUED (post 345, slot 2026-09-27). The publisher is the only
  # path that knows a post is about to become public, which is why this gate
  # runs there (bin/scheduled_posting.sh, ahead of scheduling:post_scheduled).
  #
  # THE READ IS A BAND (B1): the vision brain gives both ends of the age band it
  # can stand behind ("17-19 means the person could be 17, 18, or 19"), plus
  # the render's wardrobe tier -- SFW (clothed/covered) or EXPLICIT (visible
  # areola and beyond; the wardrobe ladder below that stays SFW here). The hold
  # matrix:
  #
  #   band                          | SFW tier       | explicit tier
  #   top below 18 (child, teen,    | HOLD           | HOLD
  #     16-17)
  #   spans 18 (17-19, late teens   | PUBLISH +      | HOLD -- fail-closed
  #     to early 20s)                 record           on ambiguity
  #   bottom at/above 18 (young     | PUBLISH +      | PUBLISH +
  #     adult, 18-25, 30s)            record           record
  #
  # The SFW row is the calibration change: a render the brain reads as "could
  # be 17 or 18" is the intended ~18yo pull, not a violation, so a band whose
  # top reaches 18 publishes at the SFW tier and is recorded. The explicit
  # tier keeps the floor strict: it publishes only on a band whose bottom is at
  # or above 18, and ANY ambiguity there -- a band that spans 18, a missing
  # TIER line, an unparseable read -- HOLDS. A "looks like a minor" read (a
  # band entirely below 18) is a hold at EVERY tier.
  #
  # TWO FAILURE DIRECTIONS, handled separately:
  #   * a CAPTION SERVICE OUTAGE (no answer) fails OPEN for every tier: a queue
  #     stall is worse than a miss, and the gate can never make the queue worse
  #     than it already is. The unreadable-read count is logged loud.
  #   * an ANSWERED but unparseable read is not evidence at the SFW tier (left
  #     unmarked, re-read next tick) but HOLDS at the explicit/unknown tier:
  #     the floor is fail-closed on ambiguity, and a read that cannot be parsed
  #     is not a verified adult.
  #
  # THE BAND COMES FROM THE AGE ANSWER SLOT: the question designates the slot,
  # the slot is the read, and the read is recorded on the row verbatim, so the
  # audit trail matches the decision. CUES prose is scanned only when the slot
  # is missing or unparseable -- adjectives in the prose must not widen a band
  # the model stated, or a "teen" read with a "youthful" cue would span 18 and
  # publish a minor (the measured 2026-10 read "AGE: teen / CUES: soft youthful
  # jawline ... indicate a minor" must stay a hold).
  #
  # A HELD post is unpublished in place: BOTH publisher clocks (scheduled_at
  # and optimal_time_calculated) are cleared and a Decision is logged -- never
  # a new status, which the post state machine does not model. The render stays
  # a reserve candidate, so the operator can clear a bad read or the planner
  # can reassign the slot; nothing is purged. Holding also feeds the queue
  # correctly: the cadence engine counts queued posts by the same two clocks,
  # so a held post drops out of the count and the next growth tick renders a
  # replacement -- the intended loop, not a stalled slot.
  #
  # EVERY decided read -- hold or pass -- is recorded on the row (verdict,
  # band, tier, model, the read text, the time), so the corpus can be audited
  # after the fact and a decided post is not re-probed hourly (each probe is a
  # ~15s model call).
  #
  # DRY-RUN BY DEFAULT (same contract as CaptionGeneration::PlaceholderRefresh
  # and ContentStrategy::QueuedHashtagBackfill): the write path is opt-in with
  # APPLY=1 via rake or dry_run: false.
  #
  # This class is a thin orchestrator: candidate selection, the probe call, and
  # the hold write. All band/verdict/hold logic is pure class methods
  # (parse / verdict / hold?) so every branch is unit-testable without a vision
  # model.
  class PersonaAgeGate
    ADULT_FLOOR = 18.0
    UNPUBLISHED_STATUSES = %w[draft scheduled].freeze
    DEFAULT_LIMIT = 2
    # Marker key in scheduling_posts.caption_metadata. A post that has been read
    # and decided is not re-probed, and a held post carries the read that held
    # it as its audit trail.
    METADATA_KEY = 'age_gate'
    # Verdicts that count as DECIDED in caption_metadata.age_gate.verdict (see
    # #already_read?).
    DECIDED_VERDICTS = %w[juvenile adult ambiguous no_person unknown].freeze

    # A parsed read: `band` is [low, high] floats, :none (no person in frame),
    # or nil (nothing parseable); `tier` is :sfw / :explicit / :unknown.
    Read = Struct.new(:band, :tier) do
      def none? = band == :none
    end

    Result = Struct.new(:post_id, :photo_id, :verdict, :read, :model, :outcome, :error,
                        :band, :tier, keyword_init: true)

    # The band probe. The question asks for the band in the AGE slot, the
    # wardrobe tier in the TIER slot, and the cues in one line -- the parser
    # reads the band from the slot first (see the class comment).
    QUESTION = <<~PROMPT.freeze
      You are a conservative age auditor. Look at the main person in this render.

      AGE: the apparent age band as two whole numbers (e.g. 17-19), the ends of
           the band you can stand behind -- 17-19 means the person could be 17,
           18, or 19. If the person is clearly one age, give a point (18). If
           the person is a child, answer "child". Answer "none" if no person is
           visible.
      TIER: SFW (clothed, covered, nothing beyond suggestive framing) or
           EXPLICIT (visible areola, nudity, or sexual content).
      CUES: one short sentence naming the facial and body cues you used.

      Answer with exactly those three lines, AGE first.
    PROMPT

    # Numeric band shapes, tried in order; every match in a stretch of read
    # text is unioned, so "17-19, maybe younger" widens toward the young end.
    NUMERIC_BANDS = [
      { pattern: /\b(\d{1,2})\s*[-\u2013]\s*(\d{1,2})\b/, kind: :range },
      { pattern: /\bbetween\s+(\d{1,2})\s+and\s+(\d{1,2})\b/, kind: :range },
      { pattern: /\b(?:under|below)\s+(\d{1,2})\b/, kind: :under },
      { pattern: /\b(?:over|above)\s+(\d{1,2})\b/, kind: :over },
      { pattern: /\b(\d{1,2})\s*\+(?!\d)/, kind: :plus },
      { pattern: /(\d{1,2}(?:\.\d)?)\s*(?:years?|yrs?|yo|y\/o|year old)\b/, kind: :point }
    ].freeze

    # The AGE answer slot may be a bare number ("AGE: about 18"); prose may not
    # -- a random digit elsewhere in the read is not an age.
    AGE_LINE_POINT = /\b(?:about|approximately|approx\.?|around|nearly|almost)?\s*(\d{1,2}(?:\.\d)?)\b/

    # Age word cues, each a [low, high] band. A cue spans 18 when the phrase
    # genuinely straddles the floor ("youthful", "late teen"); a phrase that is
    # unambiguously on one side stays on that side ("teen" tops out just below
    # 18, "adult" starts exactly at it), so a stated band is not widened by
    # the looseness of its own wording.
    WORD_CUES = [
      { pattern: /\bchild(?:ish)?\b|infant|toddler|baby/, low: 0.0, high: 12.0 },
      { pattern: /\blittle (?:girl|boy)\b/, low: 5.0, high: 10.0 },
      { pattern: /\bpre-?teen(?:s|age)?\b/, low: 9.0, high: 13.0 },
      { pattern: /\bearly (?:teens?|teenage)\b/, low: 11.0, high: 15.0 },
      { pattern: /\bmid-?teens?\b/, low: 14.0, high: 16.0 },
      { pattern: /\blate (?:teens?|teenage)\b/, low: 16.0, high: 19.0 },
      { pattern: /\bteen(?:s|age|ager)?\b|adolescent/, low: 13.0, high: 17.9 },
      { pattern: /\bminor\b/, low: 0.0, high: 17.9 },
      { pattern: /\bunderage\b|not yet adult/, low: 12.0, high: 17.9 },
      { pattern: /\byoung\s+(?:girl|boy|person)\b/, low: 0.0, high: 15.9 },
      { pattern: /\byouthful\b/, low: 13.0, high: 20.0 },
      { pattern: /\badult\b|grown|\bwoman\b|\bman\b|\blady\b|gentlewoman/, low: 18.0, high: 65.0 },
      { pattern: /\byoung adult/, low: 18.0, high: 30.0 },
      { pattern: /\bearly (?:20s|twenties)\b/, low: 20.0, high: 24.0 },
      { pattern: /\bmid-?(?:20s|30s|40s|50s|60s)\b/, low: 24.0, high: 38.0 },
      { pattern: /\b20s\b|twenties/, low: 20.0, high: 29.0 },
      { pattern: /\b30s\b|thirties/, low: 30.0, high: 39.0 },
      { pattern: /\b40s\b|forties/, low: 40.0, high: 49.0 },
      { pattern: /\b50s\b|fifties/, low: 50.0, high: 59.0 },
      { pattern: /middle-?aged|\bmature\b/, low: 40.0, high: 60.0 },
      { pattern: /\belderly\b|\bsenior\b/, low: 65.0, high: 85.0 }
    ].freeze

    def self.call(persona:, dry_run: true, limit: DEFAULT_LIMIT, now: Time.current)
      new(persona: persona, now: now).call(dry_run: dry_run, limit: limit)
    end

    # Explicit, auditable hold of a named post, using the SAME write path the
    # gate uses (clocks cleared, metadata recorded, Growth::Decision row). This
    # exists for the case the automated read cannot settle: a post flagged by an
    # earlier independent read that the gate's own probe clears. Forcing it here
    # rather than by hand-editing the row keeps the audit trail identical to an
    # automatic hold -- and the row stays reversible (both clocks are stored in
    # the Decision's reason).
    #
    # @param post [Scheduling::Post] an unpublished post with a future slot
    # @param read [String] the read that justifies the hold
    # @param reason [String] why the hold is being forced
    # @return [Result]
    def self.hold!(post:, read:, reason:, model: nil)
      gate = new(persona: post.persona)
      raise ArgumentError, 'post is not unpublished (nothing to hold)' unless UNPUBLISHED_STATUSES.include?(post.status)

      before = { scheduled_at: post.scheduled_at, optimal_time_calculated: post.optimal_time_calculated }
      raise ArgumentError, 'post has no future slot to hold' if before.values.compact.empty?

      carrier = CaptionGeneration::VisionProbe::Result.new(text: read.to_s, model: model)
      parsed = parse(read.to_s)
      verdict = verdict(parsed.band)
      post.update_columns(
        scheduled_at: nil,
        optimal_time_calculated: nil,
        caption_metadata: gate.send(:write_metadata, post, carrier, verdict: verdict,
                                    band: parsed.band, tier: parsed.tier, held: true)
      )
      gate.send(:log_hold, post, carrier, before, verdict: verdict, read: parsed)
      Growth::Decision.create!(
        goal: gate.send(:goal),
        action: 'age_gate_hold',
        reason: "forced hold (#{reason}): #{read.to_s.truncate(200)}; held post #{post.id} " \
                "(photo #{post.photo_id}) from slot #{before[:scheduled_at] || before[:optimal_time_calculated]}",
        decided_at: Time.current
      ) if gate.send(:goal)
      Result.new(post_id: post.id, photo_id: post.photo_id, verdict: verdict,
                 read: read.to_s.truncate(200), model: model, outcome: :held,
                 band: parsed.band, tier: parsed.tier)
    end

    # --- pure band/verdict/hold logic ----------------------------------------

    # Parse a probe answer into a Read: the band comes from the AGE answer slot
    # (the question designates it) and the tier from the TIER slot. PURE
    # function of the text: no network, no DB, so every branch is unit-testable
    # and two probes of the same render agree.
    def self.parse(text)
      raw = text.to_s.downcase.strip
      tier = parse_tier(raw)
      return Read.new(band: nil, tier: tier) if raw.empty?

      age_line = raw[/age\s*[:\-]\s*([^\n]*)/, 1].to_s.strip
      if age_line.match?(/\bnone\b|\bno person\b|\bno one\b|\bnot a person\b/) ||
         raw.match?(/\bno (?:person|people|one) (?:is|appears|can be)? (?:visible|present)\b/)
        return Read.new(band: :none, tier: tier)
      end

      # The AGE slot is the designated answer for the band, so it is read first
      # and wins when it parses. Prose is scanned only when the slot is missing
      # or unparseable -- it must not widen a band the model stated.
      band = band_from(age_line, age_slot: true) unless age_line.empty?
      band ||= band_from(raw)
      Read.new(band: band, tier: tier)
    end

    # The band in one stretch of read text: every numeric range/point found,
    # else every age word cue found, unioned. The AGE slot additionally accepts
    # a bare point ("AGE: about 18"). Returns [low, high] or nil when nothing
    # parses.
    def self.band_from(text, age_slot: false)
      numeric = NUMERIC_BANDS.filter_map do |spec|
        m = spec[:pattern].match(text)
        next unless m
        case spec[:kind]
        when :range
          lo, hi = m[1].to_f, m[2].to_f
          lo > hi ? [ hi, lo ] : [ lo, hi ] # tolerate a reversed range
        when :under then [ 0.0, m[1].to_f - 0.1 ]
        when :over then [ m[1].to_f + 0.1, m[1].to_f + 0.1 ]
        when :plus then [ m[1].to_f + 0.1, m[1].to_f + 0.1 ]
        when :point then [ m[1].to_f, m[1].to_f ]
        end
      end
      if numeric.empty? && age_slot
        m = AGE_LINE_POINT.match(text)
        numeric << [ m[1].to_f, m[1].to_f ] if m
      end
      return union(numeric) if numeric.any?

      words = WORD_CUES.filter_map { |cue| [ cue[:low], cue[:high] ] if cue[:pattern].match?(text) }
      words.any? ? union(words) : nil
    end

    def self.union(bands)
      [ bands.map(&:first).min, bands.map(&:last).max ]
    end

    # The TIER slot. Absent or unrecognised -> :unknown, which the hold matrix
    # treats as fail-closed (a missing tier line is ambiguity).
    def self.parse_tier(raw)
      line = raw[/tier\s*[:\-]\s*([^\n]*)/, 1].to_s.downcase.strip
      return :unknown if line.empty?
      # Negations and SFW markers are checked first: "not explicit" must not
      # match the explicit tier.
      return :sfw if line.match?(/\bnot\s+explicit\b|\bsfw\b|s\.f\.w|modest|clothed|covered|no nudity|fully dressed|nothing beyond suggestive/)
      return :explicit if line.match?(/\bexplicit\b|\bnude\b|nudity|areola|nipple|genital|\bbare\b|sexual|nsfw|unclothed/)
      :unknown
    end

    # The band's position against the floor -- the only decision the gate makes:
    #   :juvenile  the whole band is below 18 -- a "looks like a minor" read
    #   :adult     the whole band is at/above 18 -- a confident adult
    #   :ambiguous the band spans 18 -- the ~18yo pull
    #   :no_person no person in frame
    #   :unknown   the read carried no band we can parse
    def self.verdict(band)
      return :no_person if band == :none
      return :unknown if band.nil?
      low, high = band
      if high < ADULT_FLOOR
        :juvenile
      elsif low >= ADULT_FLOOR
        :adult
      else
        :ambiguous
      end
    end

    # The B1 hold matrix: a juvenile band holds at every tier; a band that
    # spans 18 publishes only at the SFW tier; an unparseable band holds
    # wherever the read is not verified SFW (the explicit floor is fail-closed
    # on ambiguity). A confident adult or a no-person read publishes.
    def self.hold?(verdict, tier)
      case verdict
      when :juvenile then true
      when :adult, :no_person then false
      when :ambiguous, :unknown then tier != :sfw
      end
    end

    # One line, for the Decision's reason and the hold log.
    def self.hold_reason(verdict, read)
      band_text = read.band.is_a?(Array) ? format('%g-%g', *read.band) : 'unreadable'
      tier = read.tier
      if verdict == :juvenile
        "render reads below the floor (band #{band_text}, tier #{tier})"
      elsif verdict == :unknown
        "render read is unparseable and the tier is #{tier} (fail-closed; band #{band_text})"
      else
        "render's band spans the floor (band #{band_text}, tier #{tier}) -- fail-closed below the SFW tier"
      end
    end

    def initialize(persona:, now: Time.current)
      @persona = persona
      @now = now
    end

    # Unpublished posts with a FUTURE slot, nearest slot first, minus the ones
    # already decided. Nearest-first matters: the publisher runs this hourly
    # with a small limit, so the posts that publish soonest are verified first.
    def candidates(limit:)
      Scheduling::Post
        .where(persona: @persona, status: UNPUBLISHED_STATUSES)
        .where.not(photo_id: nil)
        .where('scheduled_at > ? OR optimal_time_calculated > ?', @now, @now)
        .order(Arel.sql('COALESCE(scheduled_at, optimal_time_calculated) ASC'))
        .to_a
        .reject { |post| already_read?(post) }
        .first(limit)
    end

    def call(dry_run: true, limit: DEFAULT_LIMIT)
      results = candidates(limit: limit).map { |post| check(post, dry_run: dry_run) }
      unreadable = results.count { |r| r.outcome == :skipped }
      # The COUNT, loud: an individual unreadable post logs its own warning in
      # check (the gate's existing contract), but a run that cannot read AT ALL
      # — the brain serving home down — must be visible to the weekly review as
      # a number, not as N scattered lines. Fail-open is preserved: publishing
      # never waits on this line.
      if unreadable.positive?
        Rails.logger.warn("Growth::PersonaAgeGate: #{unreadable} unreadable read(s) this run " \
                          "(limit #{limit}) — the brain serving home is not answering; " \
                          "posts publish unchanged (fail-open)")
      end
      results
    end

    private

    def check(post, dry_run:)
      probe = CaptionGeneration::VisionProbe.ask(photo: post.photo, question: QUESTION)

      # FAIL-OPEN: no answer means no verdict, and no verdict means publish
      # exactly as before. Nothing is recorded, so the next tick retries.
      unless probe.ok?
        Rails.logger.warn("Growth::PersonaAgeGate: unreadable post #{post.id} " \
                          "(photo #{post.photo_id}): #{probe.error}")
        return result(post, :unknown, probe, :skipped, probe.error)
      end

      read = self.class.parse(probe.text)
      verdict = self.class.verdict(read.band)

      if self.class.hold?(verdict, read.tier)
        return result(post, verdict, probe, :would_hold, band: read.band, tier: read.tier) if dry_run

        hold(post, probe, verdict: verdict, read: read)
        return result(post, verdict, probe, :held, band: read.band, tier: read.tier)
      end

      if verdict == :unknown
        # Answered but unparseable, and the tier is SFW: not evidence, not a
        # hold -- leave it unmarked and re-read next tick (fail-open). The
        # explicit/unknown-tier case is the hold? branch above: fail-closed.
        Rails.logger.warn("Growth::PersonaAgeGate: unclassifiable read for post #{post.id} " \
                          "(SFW tier): #{probe.text.to_s.truncate(120)} -- re-read next tick")
        return result(post, :unknown, probe, :undecided, tier: read.tier)
      end

      # Decided and not a hold: record the read (band + tier + the text) so the
      # next tick does not pay for the same read again. The clocks are
      # untouched: this post publishes as normal.
      post.update_columns(caption_metadata: write_metadata(post, probe, verdict: verdict,
                                                           band: read.band, tier: read.tier, held: false)) unless dry_run
      result(post, verdict, probe, dry_run ? :would_clear : :cleared, band: read.band, tier: read.tier)
    end

    def hold(post, probe, verdict:, read:)
      before = { scheduled_at: post.scheduled_at, optimal_time_calculated: post.optimal_time_calculated }
      post.update_columns(
        scheduled_at: nil,
        optimal_time_calculated: nil,
        caption_metadata: write_metadata(post, probe, verdict: verdict, band: read.band,
                                         tier: read.tier, held: true)
      )
      log_hold(post, probe, before, verdict: verdict, read: read)
      Growth::Decision.create!(
        goal: goal,
        action: 'age_gate_hold',
        reason: "#{self.class.hold_reason(verdict, read)} (#{probe.text.to_s.truncate(200)}); " \
                "held post #{post.id} (photo #{post.photo_id}) from slot " \
                "#{before[:scheduled_at] || before[:optimal_time_calculated]}",
        decided_at: Time.current
      ) if goal
    rescue StandardError => e
      # A hold that fails must be LOUD: the post is still publishable.
      Rails.logger.error("Growth::PersonaAgeGate: could not hold post #{post.id}: #{e.class} - #{e.message}")
      raise
    end

    def log_hold(post, probe, before, verdict:, read:)
      slot = before[:scheduled_at] || before[:optimal_time_calculated]
      Rails.logger.warn("Growth::PersonaAgeGate: HELD post #{post.id} (photo #{post.photo_id}, " \
                        "slot #{slot}) — #{self.class.hold_reason(verdict, read)}: " \
                        "#{probe.text.to_s.truncate(200)}")
    end

    # Merge, never replace: caption_metadata carries the caption's own
    # provenance and must survive a gate write.
    def write_metadata(post, probe, verdict:, band:, tier:, held:)
      meta = post.caption_metadata.is_a?(Hash) ? post.caption_metadata.dup : {}
      meta[METADATA_KEY] = {
        'verdict' => verdict.to_s,
        'band' => band,
        'tier' => tier.to_s,
        'read' => probe.text.to_s.truncate(500),
        'model' => probe.model,
        'model_selection' => probe.model_selection,
        'checked_at' => Time.current.utc.iso8601,
        'held' => held
      }
      meta
    end

    def already_read?(post)
      meta = post.caption_metadata
      return false unless meta.is_a?(Hash)

      gate = meta[METADATA_KEY]
      return false unless gate.is_a?(Hash)

      # Only a DECIDED read counts as read: an unreadable/undecided probe
      # records nothing, so a retry is always attempted.
      DECIDED_VERDICTS.include?(gate['verdict'])
    end

    def result(post, verdict, probe, outcome, error = nil, band: nil, tier: nil)
      Result.new(post_id: post.id, photo_id: post.photo_id, verdict: verdict,
                 read: probe.text.to_s.truncate(200), model: probe.model,
                 outcome: outcome, error: error, band: band, tier: tier)
    end

    def goal
      @goal ||= Growth::Goal.active.for_persona(@persona).first
    end
  end
end
