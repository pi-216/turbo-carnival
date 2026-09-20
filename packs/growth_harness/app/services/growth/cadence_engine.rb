# frozen_string_literal: true

module Growth
  # Keep the scheduled-post queue full enough to hit the goal's cadence.
  #
  # MOVE-ON semantics (root cause of the NSFW stall): previously a single
  # `nsfw_rejected` ended the whole hour's sync (break on first failure). NSFW
  # rejection is PILLAR-SPECIFIC — a lingerie-drifted fashion render says
  # nothing about the cooking pillar. So cadence now rotates through the
  # persona's current pillars; on a rejection it records the shift, moves to
  # the next pillar, and retries the slot. It only hard-stalls when every
  # pillar in the pool has been exhausted.
  class CadenceEngine
    LOOKAHEAD_DAYS = 7
    # Minimum lead for a freshly generated post. The exact slot is allocated by
    # Growth::PostSlotPlanner (earliest under-cap day, spaced inside the posting
    # window) -- passing an INCREMENTING lead here is what used to push each
    # successive post a day further out and break the 7-day target window.
    MIN_LEAD_DAYS = 1

    attr_reader :goal

    def initialize(goal:)
      @goal = goal
    end

    def sync
      target = posts_target
      existing = scheduled_posts_count

      # FIRST recover renders a killed producer abandoned (see RenderSalvage):
      # paid-for GPU work that never became a post is queue content, and it is
      # cheaper to finish it than to render a replacement.
      salvage = salvage_abandoned_render(existing, target)
      existing = scheduled_posts_count if salvage[:recovered].positive?

      shortfall = [target - existing, 0].max

      return { created: 0, target: target, existing: existing, shortfall: 0, salvage: salvage } if shortfall.zero?

      created = 0
      failures = []
      config = pillar_candidates.to_a.shuffle

      while shortfall > 0 && config.any?
        result = generate_fresh(MIN_LEAD_DAYS, config.shift)

        if result[:success]
          created += 1
          shortfall -= 1
        elsif move_on?(result)
          # NSFW rejection is pillar-specific: record the shift, shift to the
          # NEXT pillar, and retry this slot. Only give up when the pool empties.
          record_pillar_shift(result)
          if config.any?
            moved = generate_fresh(MIN_LEAD_DAYS, config.shift)
            if moved[:success]
              created += 1
              shortfall -= 1
            else
              failures << "#{moved[:error] || 'unknown'} (run #{moved[:run_id]})"
              break
            end
          else
            failures << (result[:error] || 'nsfw_rejected; all pillars exhausted')
            break
          end
        else
          failures << "#{result[:error] || 'unknown'} (run #{result[:run_id]})"
          break
        end
      end

      log_blockage(failures.first) if failures.any?

      {
        created: created,
        target: target,
        existing: existing + created,
        shortfall: shortfall,
        failures: failures,
        salvage: salvage
      }
    end

    # Recover abandoned renders WITHOUT rendering and WITHOUT the GPU/scheduler.
    #
    # WHY THIS IS A SEPARATE ENTRY POINT (root cause, 2026-09-20): the recovery
    # lives at the top of #sync, and the growth tick skips its whole cadence step
    # when it cannot acquire the 4090 — the right call for RENDERING, but it also
    # gated the ONE path that needs no GPU at all. While a foreign claim held the
    # card, every hourly tick was refused (comfyui_unclaimed) and three renders
    # that had already been PAID FOR (runs 457/463/471, 2026-09-19) sat unposted
    # on disk for 13h+ while the queue drained 21 -> 19.
    #
    # Bounded by the shortfall exactly like the in-sync path, and idempotent (a
    # Photo row for the path is the marker), so an hourly caller can never
    # over-fill the queue or double-post. `result` is nil when the queue is
    # already at target — there is nothing to recover INTO.
    def recover_abandoned
      target = posts_target
      existing = scheduled_posts_count
      shortfall = [target - existing, 0].max
      result = shortfall.zero? ? nil : Growth::RenderSalvage.new(goal: goal).call(limit: shortfall)
      { target: target, existing: existing, shortfall: shortfall, result: result }
    end

    private

    # Recover renders whose sync producer was killed before the post-actions ran.
    # Bounded by the outstanding shortfall: if the queue is already full there is
    # nothing to recover INTO, and the candidates stay on disk for a later tick.
    # Failures here must never break the sync, so the whole call is rescued.
    def salvage_abandoned_render(existing, target)
      budget = [target - existing, 0].max
      result = Growth::RenderSalvage.new(goal: goal).call(limit: budget)
      {
        recovered: result.recovered,
        rejected: result.rejected,
        skipped: result.skipped,
        post_ids: result.post_ids,
        examined: result.examined
      }
    rescue StandardError => e
      Rails.logger.error("Growth::CadenceEngine salvage failed: #{e.class} - #{e.message}")
      { recovered: 0, rejected: 0, skipped: 0, post_ids: [], examined: 0 }
    end

    # How many scheduled+draft posts should be in the future queue.
    def posts_target
      (goal.effective_posts_per_day * LOOKAHEAD_DAYS).ceil
    end

    # Generate one FRESH image via turbo-one-step and schedule it (replaces
    # stale-library reuse). pillar shifts which scene bank the prompt uses.
    # min_lead_days is a floor; the slot itself comes from PostSlotPlanner.
    def generate_fresh(min_lead_days, pillar = nil)
      Growth::ContentGenerator.new(goal: goal, pillar: pillar).generate_one(offset_days: min_lead_days)
    end

    # Non-expired pillars to rotate through, heaviest first (so cadence favors
    # the current weighted share while still moving on when one is rejected).
    def pillar_candidates
      goal.persona.content_pillars.current.order(weight: :desc)
    end

    # True ONLY for NSFW rejections — the one failure mode where retrying a
    # DIFFERENT pillar is the correct move. Render/infra errors are not
    # pillar-specific and still halt.
    def move_on?(result)
      result[:error].to_s.start_with?('nsfw_rejected')
    end

    # Audit row so the experiment ledger shows the harness responded to a
    # rejection by shifting pillar rather than stalling.
    def record_pillar_shift(result)
      Growth::Decision.create!(
        goal: goal,
        action: 'pillar_shift',
        reason: "nsfw_rejected; moved to next pillar (#{result[:error]})",
        decided_at: Time.current
      )
      Rails.logger.warn("Growth::CadenceEngine pillar_shift: #{result[:error]}")
    rescue StandardError => e
      Rails.logger.error("Growth::CadenceEngine could not log pillar_shift: #{e.message}")
    end

    def scheduled_posts_count
      Scheduling::Post
        .where(persona: goal.persona)
        .where(status: %w[draft scheduled])
        .where('scheduled_at > ? OR optimal_time_calculated > ?', Time.current, Time.current)
        .count
    end

    def log_blockage(error_message)
      Growth::Decision.create!(
        goal: goal,
        action: 'cadence_blocked',
        reason: "Could not top up queue: #{error_message}",
        decided_at: Time.current
      )
      Rails.logger.warn("Growth::CadenceEngine: #{error_message}")
    end
  end
end