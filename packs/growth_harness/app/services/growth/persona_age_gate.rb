# frozen_string_literal: true

module Growth
  # Pre-publish AGE GATE: hold a queued post whose render reads as a minor.
  #
  # WHY THIS EXISTS (root cause, 2026-09-21): the account is adult-oriented and
  # nothing between a render and Instagram asked how old the person in the image
  # looks. Independent vision reads of production renders returned "a young girl,
  # likely a teenager" and "late teens or early twenties" repeatedly, stable
  # across a checkpoint change, and the newest read ("early teens to early
  # twenties") was on a render the pipeline considered shippable and had already
  # QUEUED (post 345, slot 2026-09-27). The pipeline's gates all measure
  # something else: the NSFW gate scored those images 0.0004-0.0722 (comfortably
  # safe), the realism gate measures artifice, and the prompt-safety repair
  # (c016653) removed an adult-SUPPRESSING negative token from the stored
  # workflow -- a fix to the INPUT, with no check on the OUTPUT. Every one of
  # those is a producer-side fix, and a producer-side fix cannot stop a row that
  # is already in the queue: the publisher is the only path that knows a post is
  # about to become public, which is why this gate runs there
  # (bin/scheduled_posting.sh, ahead of scheduling:post_scheduled).
  #
  # WHAT IT DOES: for each unpublished post with a future slot, ask the vision
  # model for an apparent-age read (CaptionGeneration::VisionProbe -- GPU-free,
  # it runs on the caption host, ~15s for a 1.1 MB render) and classify the
  # answer. A JUVENILE verdict HOLDS the post by clearing BOTH of the
  # publisher's clocks (scheduled_at and optimal_time_calculated). That is the
  # hold, and it is why status is not touched: `scheduling:post_scheduled`
  # selects a due post as `status=scheduled AND scheduled_at <= now` OR
  # `status=draft AND optimal_time_calculated <= now`, so a post with neither
  # clock is never released, while leaving the state machine untouched keeps the
  # row's history intact and makes the write trivially reversible.
  #
  # Holding also feeds the queue correctly with no extra machinery: the cadence
  # engine counts queued posts by the same two clocks, so a held post drops out
  # of the count, the shortfall reopens, and the next growth tick renders a
  # REPLACEMENT. That is the intended loop -- hold the juvenile render, render
  # again -- not a stalled slot.
  #
  # DIRECTION OF ERROR, deliberately chosen: the classifier errs toward HOLDING
  # when the read is ambiguous between juvenile and adult ("late teens or early
  # twenties" holds). A false hold costs one re-render of paid-for GPU work; the
  # other direction publishes a minor-reading image on a public adult account.
  # An UNREADABLE probe is the one case that does NOT hold -- a caption-service
  # outage must not stop publishing, and it is exactly today's behaviour, so the
  # gate can never make the queue worse than it already is. Unreadable and
  # undecided posts are not marked, so the next tick retries them.
  #
  # DRY-RUN BY DEFAULT (same contract as CaptionGeneration::PlaceholderRefresh
  # and ContentStrategy::QueuedHashtagBackfill): the write path is opt-in with
  # APPLY=1 via rake or dry_run: false.
  class PersonaAgeGate
    UNPUBLISHED_STATUSES = %w[draft scheduled].freeze
    DEFAULT_LIMIT = 2
    # Marker key in scheduling_posts.caption_metadata. A post that has been read
    # and cleared is not re-probed (each probe is a ~15s model call), and a held
    # post carries the read that held it as its audit trail.
    METADATA_KEY = 'age_gate'

    QUESTION = <<~PROMPT.freeze
      You are the age-verification reviewer for a public, adult-oriented
      Instagram account. Look at the person in this image and estimate their
      APPARENT AGE.

      Answer with exactly two lines and nothing else:
      AGE: <one of: child, teen, young adult, adult, middle-aged, senior, none>
      CUES: <one short sentence naming the facial and body cues you used>

      Rules:
      - Use "none" only when no person is visible.
      - "teen" covers anyone who appears to be under 18, including "late teens".
      - Judge from what is visible (face, proportions, skin), not from the outfit.
    PROMPT

    # Tokens that make a read JUVENILE. Kept as whole-ish words/phrases so
    # "young woman" (adult) cannot be caught by "young".
    JUVENILE_TOKENS = [
      'child', 'children', 'kid', 'kids', 'teen', 'teens', 'teenage', 'teenager', 'teenagers',
      'adolescent', 'adolescents', 'minor', 'minors', 'preteen', 'preteens',
      'schoolgirl', 'schoolboy', 'underage', 'under-age', 'little girl', 'little boy',
      'young girl', 'young boy', 'school age', 'high school', 'middle school',
      'primary school', 'pre-pubescent', 'pubescent'
    ].freeze

    ADULT_TOKENS = [
      'adult', 'adults', 'young adult', 'grown woman', 'grown man', 'woman', 'man',
      'lady', 'gentleman', 'twenties', 'thirties', 'forties', 'fifties', 'sixties',
      'mature', 'middle-aged', 'middle aged', 'college age', 'university', 'fully grown'
    ].freeze

    Result = Struct.new(:post_id, :photo_id, :verdict, :read, :model, :outcome, :error,
                        keyword_init: true)

    def self.call(persona:, dry_run: true, limit: DEFAULT_LIMIT, now: Time.current)
      new(persona: persona, now: now).call(dry_run: dry_run, limit: limit)
    end

    # Classify a vision read. PURE function of the text: no network, no DB, so
    # every branch is unit-testable and two probes of the same render agree.
    #
    # @return [Symbol] :juvenile, :adult, :no_person or :unknown
    def self.classify(text)
      raw = text.to_s.downcase.strip
      return :unknown if raw.empty?

      age_line = raw[/age\s*[:\-]\s*([^\n]+)/, 1].to_s.strip
      return :no_person if age_line.match?(/\bnone\b|\bno person\b|\bno one\b|\bnot a person\b/)

      # A numeric age beats prose ("she appears to be 15 years old").
      if (m = raw.match(/\b(\d{1,2})\s*(?:-|\s)?\s*(?:years?|yrs?|yo|y\/o)\b/))
        years = m[1].to_i
        return :juvenile if years.positive? && years < 18
        return :adult if years >= 18 && years < 120
      end

      # The model's own AGE line is authoritative when we can parse it.
      return :juvenile if age_line.present? && juvenile?(age_line)

      # The CUES are evidence too, and a read that names a teen cue anywhere is
      # ambiguous at best: measured 2026-09-21, one queued render answered
      # "AGE: young adult / CUES: ... suggesting a late teen or early twenties
      # age". Juvenile tokens therefore win over an adult AGE line, and over the
      # adult-token scan below -- the documented direction of error.
      return :juvenile if juvenile?(raw)

      return :adult if age_line.present? && adult?(age_line)
      return :adult if adult?(raw)

      :unknown
    end

    def self.juvenile?(text)
      JUVENILE_TOKENS.any? { |token| text.include?(token) }
    end

    def self.adult?(text)
      ADULT_TOKENS.any? { |token| text.include?(token) }
    end

    def initialize(persona:, now: Time.current)
      @persona = persona
      @now = now
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

      post.update_columns(
        scheduled_at: nil,
        optimal_time_calculated: nil,
        caption_metadata: gate.send(:write_metadata, post, CaptionGeneration::VisionProbe::Result.new(text: read, model: model), :juvenile, held: true)
      )
      gate.send(:log_hold, post, CaptionGeneration::VisionProbe::Result.new(text: "#{read} [#{reason}]", model: model), before)
      Growth::Decision.create!(
        goal: gate.send(:goal),
        action: 'age_gate_hold',
        reason: "forced hold (#{reason}): #{read.to_s.truncate(200)}; held post #{post.id} " \
                "(photo #{post.photo_id}) from slot #{before[:scheduled_at] || before[:optimal_time_calculated]}",
        decided_at: Time.current
      ) if gate.send(:goal)
      Result.new(post_id: post.id, photo_id: post.photo_id, verdict: :juvenile,
                 read: read.to_s.truncate(200), model: model, outcome: :held)
    end

    # Unpublished posts with a FUTURE slot, nearest slot first, minus the ones
    # already read. Nearest-first matters: the publisher runs this hourly with a
    # small limit, so the posts that publish soonest are verified first.
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
      candidates(limit: limit).map { |post| check(post, dry_run: dry_run) }
    end

    private

    def check(post, dry_run:)
      probe = CaptionGeneration::VisionProbe.ask(photo: post.photo, question: QUESTION)

      # FAIL-OPEN: no answer means no verdict, and no verdict means publish
      # exactly as before. Nothing is recorded, so the next tick retries.
      unless probe.ok?
        Rails.logger.warn("Growth::PersonaAgeGate: unreadable post #{post.id} " \
                          "(photo #{post.photo_id}): #{probe.error}")
        return result(post, :unreadable, probe, :skipped, probe.error)
      end

      verdict = self.class.classify(probe.text)

      case verdict
      when :juvenile
        return result(post, :juvenile, probe, :would_hold) if dry_run

        hold(post, probe)
        result(post, :juvenile, probe, :held)
      when :adult, :no_person
        # Recorded so the next tick does not pay for the same read again. The
        # clocks are untouched: this post publishes as normal.
        post.update_columns(caption_metadata: write_metadata(post, probe, verdict, held: false)) unless dry_run
        result(post, verdict, probe, dry_run ? :would_clear : :cleared)
      else
        # An answer we cannot classify is not evidence: leave it unmarked and
        # re-read next tick rather than holding on a guess.
        Rails.logger.warn("Growth::PersonaAgeGate: unclassified read for post #{post.id}: " \
                          "#{probe.text.to_s.truncate(120)}")
        result(post, :unknown, probe, :undecided)
      end
    end

    def hold(post, probe)
      before = { scheduled_at: post.scheduled_at, optimal_time_calculated: post.optimal_time_calculated }
      post.update_columns(
        scheduled_at: nil,
        optimal_time_calculated: nil,
        caption_metadata: write_metadata(post, probe, :juvenile, held: true)
      )
      log_hold(post, probe, before)
      Growth::Decision.create!(
        goal: goal,
        action: 'age_gate_hold',
        reason: "render reads juvenile (#{probe.text.to_s.truncate(200)}); held post #{post.id} " \
                "(photo #{post.photo_id}) from slot #{before[:scheduled_at] || before[:optimal_time_calculated]}",
        decided_at: Time.current
      ) if goal
    rescue StandardError => e
      # A hold that fails must be LOUD: the post is still publishable.
      Rails.logger.error("Growth::PersonaAgeGate: could not hold post #{post.id}: #{e.class} - #{e.message}")
      raise
    end

    def log_hold(post, probe, before)
      slot = before[:scheduled_at] || before[:optimal_time_calculated]
      Rails.logger.warn("Growth::PersonaAgeGate: HELD post #{post.id} (photo #{post.photo_id}, " \
                        "slot #{slot}) — apparent-age read is juvenile: #{probe.text.to_s.truncate(200)}")
    end

    # Merge, never replace: caption_metadata carries the caption's own
    # provenance and must survive a gate write.
    def write_metadata(post, probe, verdict, held:)
      meta = post.caption_metadata.is_a?(Hash) ? post.caption_metadata.dup : {}
      meta[METADATA_KEY] = {
        'verdict' => verdict.to_s,
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

      # Only a DECIDED read counts as read: an unreadable/unknown probe records
      # nothing, so a retry is always attempted.
      %w[juvenile adult no_person].include?(gate['verdict'])
    end

    def result(post, verdict, probe, outcome, error = nil)
      Result.new(post_id: post.id, photo_id: post.photo_id, verdict: verdict,
                 read: probe.text.to_s.truncate(200), model: probe.model,
                 outcome: outcome, error: error)
    end

    def goal
      @goal ||= Growth::Goal.active.for_persona(@persona).first
    end
  end
end
