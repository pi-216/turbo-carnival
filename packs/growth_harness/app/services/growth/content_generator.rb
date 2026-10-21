# frozen_string_literal: true

module Growth
  # Generates FRESH content by rendering the turbo-one-step workflow, imports
  # the output as a photo, captions it, and schedules it. This replaces the old
  # cadence path that merely *reused* stale library photos.
  class ContentGenerator
    PIPELINE_NAME = 'turbo-one-step-clean'
    FALLBACK_PIPELINE_NAME = 'turbo-one-step'
    COMFYUI_OUTPUT = '/mnt/fscache/essdee/ComfyUI/output'
    POLL_INTERVAL = 20
    MAX_POLLS = 60 # ~20 min (renders are slow + OOM-retry can add time)

    # Tags every run this service creates as SYNC-PRODUCED. This service submits
    # its own ComfyuiJob and polls it, while JobSubmitterWorker/SelectNextJob is an
    # INDEPENDENT async dispatcher that selects any run that looks unworked — so
    # without the tag it queued a second, duplicate render for the same run
    # (observed 2026-09-19: two renders per growth run, mixed flux + pony model
    # families resident in VRAM, flux OOM at SamplerCustomAdvanced).
    SYNC_PRODUCER_KEY = 'sync_producer'
    # PRD 0007 A2 (#105): the wardrobe axis value in effect for this render is
    # recorded on the run row (auditability). It is the EFFECTIVE level — the
    # pillar's rung, clamped to the current validated tier — so the record and
    # the prompt always agree (both read ContentPillars::WardrobeAxis).
    WARDROBE_LEVEL_KEY = 'wardrobe_level'

    # PRD 0007 B2 (#109): the scene negative in effect for this render, from
    # the same rung the prompt reads. It rides on the run so the graph's
    # {{negative_prompt}} token (node 79) resolves it — the areola terms move
    # out of the global negative and into the scene's own negative: a scene
    # that covers in text carries them (rung 1-8 today), a scene that exposes
    # the areola in text is free of the suppression.
    NEGATIVE_PROMPT_KEY = 'negative_prompt'

    attr_reader :goal

    # Set by poll_for_image when ComfyUI reported an execution failure, so the
    # run's failure reason can name the cause instead of calling every render
    # death a timeout. See generate_one.
    attr_reader :render_error

    def initialize(goal:, pillar: nil)
      @goal = goal
      @pillar = pillar || default_pillar
    end

    # Generate one fresh render + caption + scheduled post.
    #
    # offset_days is the MINIMUM lead in days; the exact slot is allocated by
    # Growth::PostSlotPlanner so two posts can never share a publishing tick
    # (see that class for the measured burst this replaced).
    def generate_one(offset_days: 1)
      # GPU GATE (2026-09-01): never submit a render without a live scheduler
      # claim — an unclaimed ComfyUI makes the scheduler report "idle" while
      # the GPU is busy, double-booking it. The cron brain acquires/releases
      # the claim via bin/comfyui_harness.sh; this gate is the fail-closed
      # backstop so a claim-less render is impossible.
      gate = Growth::SchedulerGate.status
      unless gate.ready?
        record_unclaimed(gate)
        return { success: false, error: 'comfyui_unclaimed' }
      end

      pipeline = resolve_pipeline
      unless pipeline
        return { success: false, error: "pipeline #{PIPELINE_NAME} not found" }
      end

      # The rung in effect is read once and BOTH the prompt and the run's
      # records derive from it (A2), so the render and the audit record can
      # never disagree. The scene negative rides on the same rung (B2).
      level = effective_wardrobe_level

      run = PipelineRun.create!(
        pipeline: pipeline,
        persona: persona,
        content_pillar: @pillar,
        name: "gen-#{Time.now.to_i}",
        prompt: build_prompt,
        target_folder: "fresh/#{@pillar&.name&.parameterize || 'gen'}",
        status: 'pending',
        variables: {
          SYNC_PRODUCER_KEY => self.class.name,
          WARDROBE_LEVEL_KEY => level,
          NEGATIVE_PROMPT_KEY => ContentPillars::WardrobeAxis.negative_for(level)
        }
      )

      step = pipeline.pipeline_steps.order(:order).first
      payload = BuildJobPayload.call!(pipeline_step: step, pipeline_run: run)
      submit = SubmitJob.call(job_payload: payload.job_payload, pipeline_step: step, pipeline_run: run)
      unless submit.success?
        finish_run(run, 'failed', reason: "submit failed: #{submit.full_error_message}")
        return { success: false, error: submit.full_error_message, run_id: run.id }
      end

      comfyjob = submit.comfyui_job
      image_path = poll_for_image(comfyjob.comfyui_job_id)

      # A node exception inside the workflow is INPUT-dependent, not a property of
      # the card: CLIPSeg found no "head"/"hand" region in THIS sample, so the WAS
      # "Bounded Image Crop with Mask" node indexed an empty mask and the whole
      # render was lost (measured 2026-09-21: run 479, `index is out of bounds for
      # dimension with size 0`; 260 such deaths all-time and in bursts -- 211 on
      # 2025-12-10, 36 on 2025-12-11, 12 on 2026-05-26 -- so this is a
      # long-standing workflow fragility, not a regression from the clean
      # pipeline). The seed is `pipeline_run.variables["seed"] + comfyui_job.id`
      # (SubmitJob#apply_job_variables), so a RESUBMIT draws a genuinely different
      # sample: one bounded retry turns a lost render into a rendered one for a
      # few minutes of a claim the tick already holds. Bounded to ONE because a
      # prompt that fails deterministically (a hand/arm close-up with no head in
      # frame) must fail the run rather than loop -- the same policy PollJobStatus
      # already applies to a retryable OOM.
      if image_path.nil? && render_error
        Rails.logger.warn("Growth::ContentGenerator retrying render after ComfyUI error: #{render_error}")
        retry_submit = SubmitJob.call(job_payload: payload.job_payload, pipeline_step: step, pipeline_run: run)
        if retry_submit.success?
          comfyjob = retry_submit.comfyui_job
          image_path = poll_for_image(comfyjob.comfyui_job_id)
        end
      end

      unless image_path
        # NAME the cause. A ComfyUI execution error is not a timeout, and the
        # difference is the whole diagnosis: measured 2026-09-21, run 479 died in
        # the workflow with `index is out of bounds for dimension with size 0`
        # (the "Bounded Image Crop with Mask" node got an EMPTY CLIPSeg head mask)
        # and every consumer -- the CadenceEngine's cadence_blocked decision row,
        # the ops board, a human -- saw only "render timed out or produced no
        # image", so the real fault had to be re-derived from the ComfyUI log.
        reason = if render_error
                   "render failed in ComfyUI: #{render_error}"
        else
                   'render timed out or produced no image'
        end
        finish_run(run, 'failed', reason: reason)
        return { success: false, error: reason, run_id: run.id, comfyjob_id: comfyjob.id }
      end

      # NSFW classifier: ADVISORY (PRD 0007 A1, founder ruling 2026-10-19 -- "0.5 as
      # the flag-only threshold and no auto-action at any score"). This block used to
      # reject the render and record an `nsfw_rejected`/`nsfw_purge` pair; it is now a
      # measurement. A flagged render is a NORMAL, successful render: the score is
      # persisted on the run and on the asset, and the selection layer / the founder's
      # tier pre-flight decide what is used.
      nsfw = Growth::NsfwGate.new.call(image_path: image_path)
      # Fail-open is the posture (this is no longer a floor control), but an unmeasured
      # score must be LOUD -- it is not a "safe" one, and a reader of the row must be
      # able to tell the two apart (`nsfw_score` stays NULL).
      if nsfw.measured?
        Rails.logger.info("Growth::ContentGenerator nsfw score=#{nsfw.nsfw_score} " \
                          "flagged=#{nsfw.flagged} | #{image_path}")
      else
        Rails.logger.warn('Growth::ContentGenerator nsfw score unmeasured ' \
                          "(#{nsfw.error || 'gate disabled'}) | #{image_path}")
      end

      # Photo-realism / quality gate: aesthetics predictor + sharpness. A render can
      # pass the NSFW measurement and still be sub-par, and THIS gate still vetoes --
      # PRD 0007 demotes it to advisory in B3 (its own ticket), so until that lands a
      # render can carry a persisted nsfw score on the run and never become an asset.
      # Scores are persisted on the run for cohort-level analysis.
      realism = Growth::RealismGate.new.call(image_path: image_path)
      metrics = {
        nsfw_score: nsfw.nsfw_score,
        aesthetic_score: realism.aesthetic_score,
        sharpness: realism.sharpness
      }
      run.update!(quality_metrics: metrics)
      unless realism.safe
        log_realism_rejection(image_path, realism, run)
        finish_run(run, 'failed', reason: "realism_rejected (#{realism.error || realism.reason})")
        return {
          success: false,
          error: "realism_rejected (#{realism.error || realism.reason})",
          run_id: run.id, comfyjob_id: comfyjob.id, image_path: image_path
        }
      end

      # Import the fresh render as a content photo
      photo = import_photo(image_path, run, nsfw)
      unless photo
        finish_run(run, 'failed', reason: 'photo import failed')
        return { success: false, error: 'photo import failed' }
      end

      # Caption it
      cap = PostAutomation::GenerateCaption.call(photo: photo, persona: persona, pillar: @pillar)
      captioned = CaptionGeneration::CaptionMetadata.success?(cap)
      caption = captioned ? cap.caption : "Fresh look ✨"

      # Schedule it. The slot is ALLOCATED, not stamped with "now + N days":
      # stamping every post with the producing tick's clock time put multiple
      # posts on one publishing hour, and the hourly publisher released them in a
      # single tick (measured 2026-09-19: three posts inside 24 s).
      slot = Growth::PostSlotPlanner.next_slot(
        persona: persona,
        posts_per_day: goal.effective_posts_per_day,
        min_lead_days: offset_days
      )
      # Hashtags: scheduling_posts has always had a hashtags column and
      # ContentStrategy::HashtagEngine has always been able to fill it, but this
      # path created every post without one -- all 197 posted items went out with
      # ZERO hashtags. Fill it here, and the publisher appends them to the caption.
      sched = Scheduling::Post.create!(
        persona: persona,
        photo: photo,
        # Link the post to the run that produced it. Without this the post is
        # orphaned from its render, and Growth::RenderSalvage#already_posted? --
        # whose whole job is "a run that already produced a post is done,
        # whatever its status says" -- cannot see it (measured 2026-09-22: posts
        # 345/347/353 carry pipeline_run_id NULL while every salvaged post 348-352
        # carries it). The Photo row is the primary idempotency marker, so this
        # was latent rather than duplicate-posting, but a guard that cannot see
        # the rows it guards is not a guard.
        pipeline_run: run,
        caption: caption,
        hashtags: hashtags_for(photo),
        caption_metadata: CaptionGeneration::CaptionMetadata.for_result(cap, placeholder: !captioned),
        status: 'scheduled',
        scheduled_at: slot,
        optimal_time_calculated: slot,
        strategy_name: 'turbo-one-step'
      )

      finish_run(run, 'completed')

      { success: true, post_id: sched.id, photo_id: photo.id, image_path: image_path, run_id: run.id }
    end

    private

    # Hashtags for this render, via the existing engine so the persona's
    # hashtag_strategy + pillar terms + safe defaults apply. Returns [] rather than
    # raising: a missing hashtag must never fail an otherwise good render.
    def hashtags_for(photo)
      ContentStrategy::HashtagEngine.generate(photo: photo, pillar: @pillar, count: 10)
    rescue StandardError => e
      Rails.logger.warn("hashtag generation failed: #{e.class} - #{e.message}")
      []
    end

    # Move the run to a TERMINAL status as soon as its outcome is known. A run left
    # 'pending' after its render finished is a lie the rest of the system believes:
    # the async selector treated it as unworked work, and the board's stuck-run
    # check alerts on it. Failures are recorded on the run, never silently dropped.
    def finish_run(run, status, reason: nil)
      return unless run

      attrs = { status: status }
      attrs[:reject_reason] = reason if reason
      run.update!(attrs)
    rescue StandardError => e
      Rails.logger.warn("Growth::ContentGenerator could not mark run #{run.id} #{status}: #{e.message}")
    end

    def persona
      goal.persona
    end

    # Prefer the SAFE pipeline (turbo-one-step-clean); fall back to the original
    # if it has not been created yet (e.g. on an old checkout).
    def resolve_pipeline
      Pipeline.find_by(name: PIPELINE_NAME) ||
        Pipeline.find_by(name: FALLBACK_PIPELINE_NAME)
    end

    def default_pillar
      # Weighted pick over current (non-expired) pillars so it stops being a
      # coin flip across 8 equally-weighted rows. Weight is recast to odds.
      pillars = persona.content_pillars.current.to_a
      return pillars.first if pillars.one?
      return nil if pillars.empty?

      weights = pillars.map { |p| [ p.weight.to_f, 1.0 ].max }
      total   = weights.sum
      roll    = rand * total
      acc     = 0.0
      pillars.each_with_index do |p, i|
        acc += weights[i]
        return p if roll <= acc
      end
      pillars.last
    end

    def build_prompt
      Growth::PillarPrompt.for_pillar(@pillar || default_pillar)
    end

    # The wardrobe axis value in effect for this render: the pillar's rung,
    # clamped to the current validated tier. This is the SAME value the prompt
    # embeds (both read ContentPillars::WardrobeAxis), so the run row records
    # exactly what was rendered — the audit trail the axis needs (PRD 0007 A2).
    def effective_wardrobe_level
      ContentPillars::WardrobeAxis.effective_level(@pillar || default_pillar)
    end

    def poll_for_image(comfyui_job_id)
      client = ComfyuiClient.new
      MAX_POLLS.times do |i|
        begin
          s = client.get_job_status(comfyui_job_id)
        rescue StandardError => e
          sleep POLL_INTERVAL
          next
        end

        if s[:status] == 'completed'
          node = s[:output] || {}
          img = nil
          node.each do |_nid, payload|
            # get_job_status deep_symbolizes keys, but be tolerant of both
            p = payload.is_a?(Hash) ? payload : {}
            images = p[:images] || p['images']
            next unless images.present?

            img = images.first
            break
          end
          return nil unless img

          filename = img[:filename] || img['filename']
          subfolder = img[:subfolder] || img['subfolder']
          return File.join(COMFYUI_OUTPUT, subfolder.to_s, filename) if filename
        elsif s[:status] == 'failed'
          @render_error = s[:error].to_s.strip.presence || comfyui_job_error(comfyui_job_id)
          Rails.logger.warn("Growth::ContentGenerator render failed: #{@render_error}")
          return nil
        end
        # not_found → still queued/executing; keep polling
        sleep POLL_INTERVAL
      end
      # The poll budget ran out. A job that FAILED late -- a slow render, a long
      # queue -- never reached the branch above, so its cause would be recorded
      # as "timed out" and the bounded retry would be skipped: exactly the two
      # behaviours this class was fixed to provide. The error text lands on the
      # ComfyuiJob row (PollJobStatus writes it), so read it before giving up.
      @render_error ||= comfyui_job_error(comfyui_job_id)
      nil
    end

    # The ComfyUI error text for a job, from the record PollJobStatus writes.
    # Used only as a fallback when the client's own failed-status payload carries
    # no message, so the caller can still name the cause.
    def comfyui_job_error(comfyui_job_id)
      ComfyuiJob.find_by(comfyui_job_id: comfyui_job_id)&.error_message.to_s.strip.presence
    rescue StandardError
      nil
    end

    # GPU gate rejection: no live scheduler claim means renders are skipped, not
    # attempted. Audited so the brain can distinguish 'GPU not acquired' from
    # NSFW/realism/caption failures.
    def record_unclaimed(gate)
      Growth::Decision.create!(
        goal: goal,
        action: 'comfyui_unclaimed',
        reason: "render skipped — no claim (#{gate.claim_state}, comfyui #{gate.comfyui_up ? 'up' : 'down'}) | #{gate.raw}",
        decided_at: Time.current
      )
      Rails.logger.warn("Growth::ContentGenerator comfyui_unclaimed: #{gate.raw}")
    rescue StandardError => e
      Rails.logger.error("Growth::ContentGenerator could not log comfyui_unclaimed: #{e.message}")
    end

    # Photo-realism rejection: log the decision (so the harness brain can
    # distinguish "unsafe" from "sub-par" content) and record the run's
    # reject_reason for cohort-level analysis.
    def log_realism_rejection(image_path, realism, run)
      reason = if realism.error
                 "realism gate error: #{realism.error}"
      else
                 "realism rejected (aesthetic=#{realism.aesthetic_score} sharpness=#{realism.sharpness}): #{realism.reason}"
      end
      run.update!(reject_reason: reason)
      Growth::Decision.create!(
        goal: goal,
        action: 'realism_rejected',
        reason: "#{reason} | #{image_path}",
        decided_at: Time.current
      )
      Rails.logger.warn("Growth::ContentGenerator #{reason} | #{image_path}")
    rescue StandardError => e
      Rails.logger.error("Growth::ContentGenerator could not log realism rejection: #{e.message}")
    end

    def import_photo(image_path, run, nsfw = nil)
      return nil unless image_path && File.exist?(image_path)

      # The NSFW MEASUREMENT rides the import choke point (PRD 0007 A1): the score
      # belongs on the asset row, not only on the run, because the selection layer and
      # the tier pre-flight ask about the ASSET.
      ContentPillars::Photo.import_render(
        path: image_path,
        persona: persona,
        content_pillar: @pillar,
        run: run,
        nsfw_score: nsfw&.nsfw_score,
        nsfw_flagged: nsfw&.flagged
      )
    end
  end
end
