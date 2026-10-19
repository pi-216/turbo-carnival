# frozen_string_literal: true

module Growth
  # Spend the render LIBRARY -- photos already rendered, never posted -- when the
  # fresh-render path cannot keep the publish queue above its runway.
  #
  # WHY THIS EXISTS
  # Every other GPU-drought mitigation in this repo recovers renders that were
  # PAID FOR but never turned into posts (Growth::RenderSalvage). None of them can
  # do anything when NO render happens at all, and that is the recurring shape
  # here: the harness refuses to submit to a :8188 ComfyUI launched without
  # --reserve-vram (the measured over-commit OOM), so another project's supervisor
  # or the operator's own session can block rendering for hours (render-starved:
  # 1.5-96h holds, recurring since 2026-08-16). The queue then drains at the
  # publisher's cadence (~3/day) toward silence -- the one failure with no symptom
  # until the last clock passes and nothing is published.
  #
  # The library is the only content source that needs no GPU: photos already in
  # the corpus, unposted and servable. Measured 2026-09-23 against the pipeline's
  # OWN gates: 51 servable unposted photos, of which only **8 are spendable**.
  # Both halves of the library fail for measured reasons:
  #   * August (23 photos, ids 225-308): 8 pass BOTH gates; the other 15 are
  #     NSFW-classified (0.68-0.9999 -- e.g. 241 scores 0.9992). Those are the
  #     debris of the accept-loop failure this lever exists to cover.
  #   * May (28 photos, ids 124-153): pass NsfwGate cleanly (0.0001-0.0222) but
  #     ALL 28 fail RealismGate on sharpness (6.7-16.1 vs the 30.0 floor) --
  #     aesthetics are fine (5.4-7.3), the images are simply soft. Verified by
  #     hand, not inferred: the pixels reproduce the gate's Laplacian variance
  #     exactly (numpy, 512px grayscale) and a visual read of photo 124 shows
  #     genuine blur against photo 308's clear detail. The older auto-* generator
  #     produced soft renders; the threshold sits in an empty valley (nothing
  #     scores between 16 and 121), so no borderline case is being cut.
  #
  # That is the reason this class gates EVERY photo it touches -- the library is
  # not a pre-vetted pool, it is older renders of mixed provenance -- and it is
  # also the honest size of the lever: **8 photos is ~2.7 days at a 3/day
  # cadence**, NOT the multi-week buffer an ungated count of 51 suggests. Do not
  # size a hold against the raw candidate count; re-measure the gates.
  #
  # The depth is a COMMAND now, not a remembered number: `bin/library_depth.py`
  # (GPU-free, CPU-only, ~30s) runs these same gates in batch over the current
  # candidate set and writes `ops/library_depth.json`; `bin/tc_ops.py queue` prints
  # the resulting SILENCE date, and the board's `publish-silence-forecast` check
  # escalates on it. Re-run the command after any render batch lands -- a stored
  # "8" rots exactly the way the raw "51" did (it was quoted as depth in an ops
  # report within a day of this measurement).
  #
  # TODO(measurement gap): the May batch's RealismGate verdict was recorded here
  # on 2026-09-23 but the photos stay in the library. If a future render stack
  # legitimately produces soft images, revisit SHARPNESS_THRESHOLD rather than
  # widening this lever.
  #
  # RULES (each guards a specific misuse)
  #   * RUNWAY-TRIGGERED, never opportunistic. It acts only when the last future
  #     clock is inside RUNWAY_TRIGGER_H -- the SAME 72h threshold the ops board
  #     escalates on (bin/tc_ops.py RUNWAY_ALERT_H), so the lever and the alarm can
  #     never disagree about when the queue is short. Fresh renders stay the
  #     primary source; the library is spent only to prevent publishing SILENCE.
  #     `force: true` exists for a human/agent running the rake task by hand.
  #   * TOPS UP TO RUNWAY_TARGET_H, not to the cadence target: a fallback that
  #     filled the whole 7-day window would spend the entire library in one hold.
  #     The remainder stays on disk for the next time.
  #   * GATES RE-RUN, fail-closed (same contract as RenderSalvage): a library photo
  #     predates the current gate stack or its producer died before gating. A
  #     rejection is recorded as a Growth::Decision and never scheduled.
  #   * IDEMPOTENT: the selector excludes any photo a post already references, and
  #     (photo_id, persona_id) is UNIQUE on scheduling_posts -- index
  #     `index_posts_on_photo_id_and_persona_id`, created by the original
  #     create_scheduling_posts migration (20251209222756) and mirrored in
  #     db/schema.rb, so it is ENFORCED BY THE DATABASE and not only by this
  #     class's `exists?` -- so a repeat call cannot double-post, and the post row
  #     is its own marker. Scheduling::Post also validates it (2026-09-23) so the
  #     human-facing scheduling form reports a duplicate instead of raising
  #     RecordNotUnique. The DB half is what makes this safe to run from three
  #     independent drivers at once (bin/scheduled_posting.sh hourly,
  #     Growth::AbandonedRenderWorker every 5 min, CadenceEngine#sync): they are
  #     triggered by the same condition and select the same candidates, so an
  #     interleaved pair both passes `exists?`. Pinned by
  #     spec/models/scheduling/post_photo_uniqueness_spec.rb -- do NOT re-add a
  #     second unique index on these columns.
  #   * BUYS RUNWAY ONLY -- it CANNOT feed Growth::GateRead's cohort. That cohort
  #     requires `photos.created_at >= INTERVENTION_AT` (2026-09-21T23:35Z); every
  #     spendable library photo here is dated 08-23..08-30, so a post built from
  #     one is a pre-intervention render wearing a fresh post row and contributes
  #     nothing to the strategy read. Do not treat this lever as a mitigation for
  #     gate-cohort-starved -- only a fresh render can be a cohort member, and that
  #     is exactly what the GPU hold blocks.
  class LibraryFallback
    RUNWAY_TRIGGER_H = 72
    RUNWAY_TARGET_H = 96
    MAX_PER_CALL = 3
    # Bound the GATE spend, not just the post count. Every candidate costs two
    # classifier invocations (~8s on this box measured 2026-09-23), the library
    # holds mostly pre-gate renders whose verdict was never recorded, and this runs
    # on the publisher's critical path -- so a call scans at most this many.
    MAX_EXAMINE = 12
    STRATEGY_NAME = 'library-fallback'
    HOURS_PER_DAY = 24.0
    REJECTED_PREFIXES = %w[nsfw_rejected realism_rejected].freeze

    Result = Struct.new(:created, :rejected, :skipped, :post_ids, :examined,
                        :runway_hours, :budget, :triggered, :reason,
                        keyword_init: true)

    attr_reader :goal

    def initialize(goal:, captioner: nil, logger: Rails.logger)
      @goal = goal
      @captioner = captioner
      @logger = logger
    end

    # @param limit [Integer, nil] hard cap on posts created this call
    # @param force [Boolean] ignore the runway trigger (manual invocation)
    def call(limit: nil, force: false)
      @rejections = []
      runway = remaining_runway_hours
      result = Result.new(created: 0, rejected: 0, skipped: 0, post_ids: [],
                          examined: 0, runway_hours: runway.round(1), budget: 0,
                          triggered: false, reason: nil)

      unless force || runway <= RUNWAY_TRIGGER_H
        result.reason = "runway #{result.runway_hours}h > #{RUNWAY_TRIGGER_H}h trigger -- library untouched"
        return result
      end

      result.triggered = true
      # `force` (manual invocation) ignores the trigger AND the target-based
      # budget: the caller is deliberately pre-buffering, so it spends up to its
      # own limit. MAX_PER_CALL still binds -- no single call may drain the library.
      result.budget = if force
                        [ (limit.to_i.positive? ? limit.to_i : MAX_PER_CALL), MAX_PER_CALL ].min
      else
                        top_up_budget(runway, limit)
      end
      if result.budget.zero?
        result.reason = 'nothing to top up'
        return result
      end

      candidates.each do |photo|
        break if result.created >= result.budget
        break if result.examined >= MAX_EXAMINE

        result.examined += 1
        outcome, post_id = spend(photo)
        case outcome
        when :created
          result.created += 1
          result.post_ids << post_id
        when :rejected then result.rejected += 1
        else                result.skipped += 1
        end
      end

      record_rejections(result) if result.rejected.positive?

      if result.created.positive?
        record_decision('library_fallback',
                        "spent #{result.created} library photo(s) — runway was " \
                        "#{result.runway_hours}h (trigger #{RUNWAY_TRIGGER_H}h); " \
                        "posts #{result.post_ids.inspect}")
        @logger.warn("Growth::LibraryFallback spent #{result.created} library photo(s) into posts #{result.post_ids.inspect}")
      else
        result.reason ||= "no spendable library photo among #{result.examined} candidate(s) " \
                          "(#{result.rejected} gate-rejected, #{result.skipped} skipped)"
      end
      result
    rescue StandardError => e
      # Never let a fallback break the publisher or the cadence sync it is bolted onto.
      @logger.error("Growth::LibraryFallback failed: #{e.class} - #{e.message}")
      result || Result.new(created: 0, rejected: 0, skipped: 0, post_ids: [], examined: 0,
                           runway_hours: 0.0, budget: 0, triggered: false, reason: "error: #{e.class}")
    end

    # The publish runway: hours until the LAST future clock passes. Same predicate
    # the ops board forecasts with (draft/scheduled + a future clock), so the
    # trigger and the escalation cannot disagree. Zero when the queue is empty.
    def remaining_runway_hours
      last = Scheduling::Post
             .where(persona_id: goal.persona_id, status: %w[draft scheduled])
             .where("#{CLOCK_SQL} > ?", Time.current)
             .maximum(Arel.sql(CLOCK_SQL))
      return 0.0 unless last

      (last - Time.current) / 3600.0
    end

    private

    CLOCK_SQL = 'coalesce(scheduled_at, optimal_time_calculated)'

    # How many posts are needed to push the runway back out to RUNWAY_TARGET_H.
    # Each post buys 24/posts_per_day hours, so a 3/day cadence needs 3 posts per
    # extra day. Clamped to MAX_PER_CALL so one hold can never drain the library.
    def top_up_budget(runway, limit)
      per_day = [ goal.effective_posts_per_day.to_f, 0.1 ].max
      hours_per_post = HOURS_PER_DAY / per_day
      needed = ((RUNWAY_TARGET_H - runway) / hours_per_post).ceil
      cap = [ MAX_PER_CALL, limit.to_i.positive? ? limit.to_i : MAX_PER_CALL ].min
      needed.clamp(0, cap)
    end

    # Newest first, servable, not referenced by any post — the pipeline's own
    # selector, so this class can never offer bytes the publish path cannot serve.
    def candidates
      Photos::ListAvailable.call(persona: goal.persona).photos
    rescue StandardError => e
      @logger.warn("Growth::LibraryFallback could not list the library: #{e.class} - #{e.message}")
      []
    end

    def spend(photo)
      path = photo.servable_file_path
      return [ :skipped, nil ] if path.blank? || !File.file?(path)
      return [ :skipped, nil ] if Scheduling::Post.exists?(photo_id: photo.id, persona_id: goal.persona_id)
      # A run that already recorded a gate rejection is not resurrected and the
      # gate is not paid for twice -- the SAME deterministic-gate rule
      # Growth::RenderSalvage applies. (Library photos predate both the gate stack
      # and the reason column in the general case, so this skips the few that do
      # carry a verdict, not the bulk.)
      return [ :skipped, nil ] if gate_rejected?(photo)

      nsfw = Growth::NsfwGate.new.call(image_path: path)
      unless nsfw.safe
        @rejections << "#{photo.id} (nsfw #{nsfw.error || "score=#{nsfw.nsfw_score}"})"
        return [ :rejected, nil ]
      end

      realism = Growth::RealismGate.new.call(image_path: path)
      unless realism.safe
        @rejections << "#{photo.id} (realism #{realism.error || realism.reason})"
        return [ :rejected, nil ]
      end

      post = schedule_post(photo, nsfw, realism)
      return [ :skipped, nil ] unless post

      [ :created, post.id ]
    end

    def gate_rejected?(photo)
      run = photo.image_candidate&.pipeline_run
      return false unless run

      reason = run.reject_reason.to_s
      REJECTED_PREFIXES.any? { |prefix| reason.include?(prefix) }
    rescue StandardError
      false
    end

    # ONE decision per call, naming the ids: a per-photo row would write up to
    # MAX_EXAMINE rows an hour for as long as the drought lasts, from a fact that
    # never changes (the gates are deterministic on the same bytes).
    def record_rejections(result)
      record_decision('library_rejected',
                      "gate rejected #{result.rejected} of #{result.examined} library " \
                      "candidate(s): #{@rejections.first(6).join(', ')}; never scheduled")
    end

    def schedule_post(photo, nsfw, realism)
      pillar = photo.content_pillar || fallback_pillar
      cap = caption_result_for(photo, pillar)
      captioned = CaptionGeneration::CaptionMetadata.success?(cap)
      slot = Growth::PostSlotPlanner.next_slot(
        persona: goal.persona,
        posts_per_day: goal.effective_posts_per_day
      )
      Scheduling::Post.create!(
        persona: goal.persona,
        photo: photo,
        caption: captioned ? cap.caption : 'Fresh look ✨',
        hashtags: hashtags_for(photo, pillar),
        caption_metadata: CaptionGeneration::CaptionMetadata.for_result(cap, placeholder: !captioned)
                                  .merge('library_fallback' => {
                                           'nsfw_score' => nsfw.nsfw_score,
                                           'aesthetic_score' => realism.aesthetic_score,
                                           'sharpness' => realism.sharpness
                                         }),
        status: 'scheduled',
        scheduled_at: slot,
        optimal_time_calculated: slot,
        strategy_name: STRATEGY_NAME
      )
    rescue StandardError => e
      @logger.warn("Growth::LibraryFallback could not schedule photo #{photo.id}: #{e.class} - #{e.message}")
      nil
    end

    def caption_result_for(photo, pillar)
      captioner.call(photo: photo, persona: goal.persona, pillar: pillar)
    rescue StandardError => e
      @logger.warn("Growth::LibraryFallback caption failed: #{e.class} - #{e.message}")
      nil
    end

    def captioner
      @captioner || PostAutomation::GenerateCaption
    end

    def hashtags_for(photo, pillar)
      ContentStrategy::HashtagEngine.generate(photo: photo, pillar: pillar, count: 10)
    rescue StandardError => e
      @logger.warn("Growth::LibraryFallback hashtag generation failed: #{e.class} - #{e.message}")
      []
    end

    def fallback_pillar
      goal.persona.content_pillars.current.order(weight: :desc).first
    end

    def record_decision(action, reason)
      Growth::Decision.create!(goal: goal, action: action, reason: reason, decided_at: Time.current)
    rescue StandardError => e
      @logger.error("Growth::LibraryFallback could not record #{action}: #{e.message}")
    end
  end
end
