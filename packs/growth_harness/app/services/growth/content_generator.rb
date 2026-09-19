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

    attr_reader :goal

    def initialize(goal:, pillar: nil)
      @goal = goal
      @pillar = pillar || default_pillar
    end

    # Generate one fresh render + caption + scheduled post.
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

      run = PipelineRun.create!(
        pipeline: pipeline,
        persona: persona,
        content_pillar: @pillar,
        name: "gen-#{Time.now.to_i}",
        prompt: build_prompt,
        target_folder: "fresh/#{@pillar&.name&.parameterize || 'gen'}",
        status: 'pending',
        variables: { SYNC_PRODUCER_KEY => self.class.name }
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
      unless image_path
        finish_run(run, 'failed', reason: 'render timed out or produced no image')
        return { success: false, error: 'render timed out or produced no image', run_id: run.id, comfyjob_id: comfyjob.id }
      end

      # NSFW gate: a third-party ViT classifier (Falconsai/nsfw_image_detection)
      # must accept the render before it can enter the photo library / queue.
      gate = Growth::NsfwGate.new.call(image_path: image_path)
      unless gate.safe
        log_rejection(image_path, gate)
        finish_run(run, 'failed', reason: "nsfw_rejected (#{gate.error || "label=#{gate.label} score=#{gate.nsfw_score}"})")
        return {
          success: false,
          error: "nsfw_rejected (#{gate.error || "label=#{gate.label} score=#{gate.nsfw_score}"})",
          run_id: run.id, comfyjob_id: comfyjob.id, image_path: image_path
        }
      end

      # Photo-realism / quality gate: aesthetics predictor + sharpness. A render
      # can be safe (passes NSFW) yet still be sub-par; it must also pass this
      # gate. Scores are persisted on the run for cohort-level analysis.
      realism = Growth::RealismGate.new.call(image_path: image_path)
      metrics = {
        nsfw_score: gate.nsfw_score,
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
      photo = import_photo(image_path, run)
      unless photo
        finish_run(run, 'failed', reason: 'photo import failed')
        return { success: false, error: 'photo import failed' }
      end

      # Caption it
      cap = PostAutomation::GenerateCaption.call(photo: photo, persona: persona, pillar: @pillar)
      captioned = CaptionGeneration::CaptionMetadata.success?(cap)
      caption = captioned ? cap.caption : "Fresh look ✨"

      # Schedule it
      # Hashtags: scheduling_posts has always had a hashtags column and
      # ContentStrategy::HashtagEngine has always been able to fill it, but this
      # path created every post without one -- all 197 posted items went out with
      # ZERO hashtags. Fill it here, and the publisher appends them to the caption.
      sched = Scheduling::Post.create!(
        persona: persona,
        photo: photo,
        caption: caption,
        hashtags: hashtags_for(photo),
        caption_metadata: CaptionGeneration::CaptionMetadata.for_result(cap, placeholder: !captioned),
        status: 'scheduled',
        scheduled_at: Time.current + offset_days.days,
        optimal_time_calculated: Time.current + offset_days.days,
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

      weights = pillars.map { |p| [p.weight.to_f, 1.0].max }
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
          Rails.logger.warn("Growth::ContentGenerator render failed: #{s[:error]}")
          return nil
        end
        # not_found → still queued/executing; keep polling
        sleep POLL_INTERVAL
      end
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

    # Record an auditable rejection decision and warn in the log. The image
    # stays in ComfyUI's output tree (Tim's playground) but never enters the
    # photo library or queue.
    def log_rejection(image_path, gate)
      reason = if gate.error
                 "nsfw gate error: #{gate.error}"
               else
                 "nsfw rejected by #{gate.label} score=#{gate.nsfw_score} (threshold=#{gate.threshold})"
               end
      Growth::Decision.create!(
        goal: goal,
        action: 'nsfw_rejected',
        reason: "#{reason} | #{image_path}",
        decided_at: Time.current
      )
      Rails.logger.warn("Growth::ContentGenerator #{reason} | #{image_path}")
    rescue StandardError => e
      Rails.logger.error("Growth::ContentGenerator could not log rejection: #{e.message}")
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

    def import_photo(image_path, run)
      return nil unless image_path && File.exist?(image_path)

      photo = ContentPillars::Photo.find_by(path: image_path)
      return photo if photo

      ContentPillars::Photo.create!(
        persona: persona,
        path: image_path,
        content_pillar: @pillar,
        image_candidate: nil
      )
    rescue ActiveRecord::RecordInvalid
      ContentPillars::Photo.find_by(path: image_path)
    end
  end
end