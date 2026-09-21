# frozen_string_literal: true

module Growth
  # Recover renders that were PAID FOR but never turned into posts.
  #
  # WHY THIS EXISTS
  # Growth::ContentGenerator is a SYNCHRONOUS producer: it creates a run, submits
  # its own ComfyuiJob, polls the render to completion and only then imports /
  # captions / schedules the post. Every one of those post-actions happens inside
  # the producer process. The growth tick runs that producer inside a cron tool
  # call with a foreground timeout, so when a render outlives the tick's budget
  # the process is SIGKILLed and the render is orphaned: ComfyuiJob -> completed,
  # an active ImageCandidate on disk, no Photo row, no post. Observed 2026-09-19:
  # run 471's render (gen-1789837275_00001_.png) completed at 17:04:53Z and was
  # still unposted an hour later; ReconcileStaleRuns then marked the RUN failed
  # so the probes would go quiet — which bounds the bookkeeping damage but throws
  # the GPU time away.
  #
  # RULE: a finished render is recoverable work, not debris. If a sync-produced
  # run has an active candidate whose file is still on disk, no Photo row for
  # that path, and the run has been untouched past the abandonment grace, re-run
  # the gates and finish the pipeline: import -> caption -> schedule.
  #
  # Safety properties (each one matters):
  #   * ABANDONED_AFTER grace — a live producer is never raced into a duplicate
  #     post; only runs that have not moved for 30 min are eligible.
  #   * Gate re-run — a killed producer may have died BEFORE the NSFW / realism
  #     gates, so both gates run again here and a rejection is recorded, never
  #     scheduled. Runs whose reject_reason already names a gate rejection are
  #     skipped outright (deterministic gates; no point paying for them twice).
  #   * Photo row = idempotency marker — a path that already has a Photo has been
  #     imported by someone (producer or an earlier salvage) and is skipped, so
  #     re-running this service can never double-post.
  #   * One candidate per run — a run that already produced a post is not mined
  #     for a second one.
  #   * Sync-produced runs only (the async dispatcher's runs are live work and
  #     must never be touched).
  #
  # It does NOT fix the kill itself (that is the tick's launch mode, outside this
  # repo) — it converts the waste the kill leaves behind back into queue content.
  class RenderSalvage
    SYNC_PRODUCER_KEY = 'sync_producer'
    MAX_AGE = 7.days
    ABANDONED_AFTER = 30.minutes
    STRATEGY_NAME = 'render-salvage'
    REJECTED_PREFIXES = %w[nsfw_rejected realism_rejected].freeze

    Result = Struct.new(:recovered, :rejected, :skipped, :post_ids, :examined, keyword_init: true)

    attr_reader :goal

    def initialize(goal:, captioner: nil, logger: Rails.logger)
      @goal = goal
      @captioner = captioner
      @logger = logger
    end

    # @param limit [Integer] max posts to recover this call (the cadence shortfall)
    def call(limit:)
      result = Result.new(recovered: 0, rejected: 0, skipped: 0, post_ids: [], examined: 0)
      limit = limit.to_i
      return result if limit <= 0

      abandoned_candidates.each do |candidate|
        break if result.recovered >= limit

        result.examined += 1
        outcome, post_id = salvage(candidate)
        case outcome
        when :recovered
          result.recovered += 1
          result.post_ids << post_id if post_id
        when :rejected  then result.rejected += 1
        else                 result.skipped += 1
        end
      end

      if result.recovered.positive?
        @logger.info("Growth::RenderSalvage recovered #{result.recovered} abandoned render(s) into scheduled posts")
      end
      result
    rescue StandardError => e
      # Never let recovery break the cadence sync it is bolted onto.
      @logger.error("Growth::RenderSalvage failed: #{e.class} - #{e.message}")
      result
    end

    private

    # Candidates of sync-produced runs that have been untouched past the grace,
    # still have their file, and have no Photo row yet.
    def abandoned_candidates
      runs = PipelineRun
             .where(persona_id: goal.persona_id)
             .where("(pipeline_runs.variables ->> :key) IS NOT NULL", key: SYNC_PRODUCER_KEY)
             .where('pipeline_runs.updated_at > ?', MAX_AGE.ago)
             .where('pipeline_runs.updated_at < ?', ABANDONED_AFTER.ago)
             .order(:id)

      runs = runs.reject { |run| gate_rejected?(run) || already_posted?(run) }
      return [] if runs.empty?

      candidates = ImageCandidate
                   .where(pipeline_run_id: runs.map(&:id), status: 'active')
                   .order(:id)
                   .to_a

      # One candidate per run: a run that already yielded a post is not mined again.
      candidates = candidates.group_by(&:pipeline_run_id).values.map(&:first)
      candidates.select { |candidate| recoverable?(candidate) }
    end

    # The producer already ran a deterministic gate on this run and the image was
    # rejected — do not resurrect it (and do not pay for the gate twice).
    def gate_rejected?(run)
      reason = run.reject_reason.to_s
      REJECTED_PREFIXES.any? { |prefix| reason.include?(prefix) }
    end

    # A run that already produced a post is done, whatever its status says.
    def already_posted?(run)
      Scheduling::Post.where(pipeline_run_id: run.id).exists?
    rescue StandardError
      false
    end

    def recoverable?(candidate)
      path = candidate.image_path.to_s
      return false if path.empty?
      return false unless File.file?(path)
      return false if ContentPillars::Photo.exists?(path: path)

      true
    end

    def salvage(candidate)
      run = candidate.pipeline_run
      path = candidate.image_path

      nsfw = Growth::NsfwGate.new.call(image_path: path)
      unless nsfw.safe
        record(run, 'salvage_rejected', "nsfw gate re-run rejected the recovered render (#{nsfw.error || "label=#{nsfw.label} score=#{nsfw.nsfw_score}"})")
        return [:rejected, nil]
      end

      realism = Growth::RealismGate.new.call(image_path: path)
      unless realism.safe
        record(run, 'salvage_rejected', "realism gate re-run rejected the recovered render (#{realism.error || realism.reason})")
        return [:rejected, nil]
      end

      photo = import_photo(run, path)
      return [:skipped, nil] unless photo

      post = schedule_post(run, photo, nsfw, realism)
      return [:skipped, nil] unless post

      run.update!(quality_metrics: run.quality_metrics.merge(
        'nsfw_score' => nsfw.nsfw_score,
        'aesthetic_score' => realism.aesthetic_score,
        'sharpness' => realism.sharpness,
        'salvaged_post_id' => post.id
      ))
      record(run, 'salvage_recovered', "recovered an abandoned render into post #{post.id} (photo #{photo.id}); producer was killed before the post-actions ran")
      [:recovered, post.id]
    end

    def import_photo(run, path)
      photo = ContentPillars::Photo.import_render(
        path: path,
        persona: goal.persona,
        content_pillar: run.content_pillar || fallback_pillar,
        run: run
      )
      @logger.warn("Growth::RenderSalvage could not import #{path}") unless photo
      photo
    end

    def schedule_post(run, photo, nsfw, realism)
      pillar = run.content_pillar || fallback_pillar
      cap = caption_result_for(photo, pillar)
      captioned = CaptionGeneration::CaptionMetadata.success?(cap)
      # Allocated slot, not a stamped clock time -- a salvage batch must not stack
      # onto one publishing tick any more than a fresh sync does.
      slot = Growth::PostSlotPlanner.next_slot(
        persona: goal.persona,
        posts_per_day: goal.effective_posts_per_day
      )
      Scheduling::Post.create!(
        persona: goal.persona,
        photo: photo,
        pipeline_run: run,
        caption: captioned ? cap.caption : 'Fresh look ✨',
        hashtags: hashtags_for(photo, pillar),
        caption_metadata: CaptionGeneration::CaptionMetadata.for_result(cap, placeholder: !captioned),
        status: 'scheduled',
        scheduled_at: slot,
        optimal_time_calculated: slot,
        strategy_name: STRATEGY_NAME
      )
    rescue StandardError => e
      @logger.warn("Growth::RenderSalvage could not schedule recovered render: #{e.class} - #{e.message}")
      nil
    end

    # The caption result is kept (not just its text) so the model that answered
    # and the failure reason can be persisted on the post -- a recovered post that
    # shipped 'Fresh look ✨' must be countable afterwards, not just logged once.
    def caption_result_for(photo, pillar)
      captioner.call(photo: photo, persona: goal.persona, pillar: pillar)
    rescue StandardError => e
      @logger.warn("Growth::RenderSalvage caption failed: #{e.class} - #{e.message}")
      nil
    end

    def captioner
      @captioner || PostAutomation::GenerateCaption
    end

    def hashtags_for(photo, pillar)
      ContentStrategy::HashtagEngine.generate(photo: photo, pillar: pillar, count: 10)
    rescue StandardError => e
      @logger.warn("Growth::RenderSalvage hashtag generation failed: #{e.class} - #{e.message}")
      []
    end

    def fallback_pillar
      goal.persona.content_pillars.current.order(weight: :desc).first
    end

    def record(run, action, reason)
      Growth::Decision.create!(
        goal: goal,
        action: action,
        reason: "#{reason} (run #{run.id})",
        decided_at: Time.current
      )
      @logger.warn("Growth::RenderSalvage #{action}: run #{run.id} - #{reason}")
    rescue StandardError => e
      @logger.error("Growth::RenderSalvage could not record #{action} for run #{run.id}: #{e.message}")
    end
  end
end
