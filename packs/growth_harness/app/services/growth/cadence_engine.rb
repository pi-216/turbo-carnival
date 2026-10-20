# frozen_string_literal: true

module Growth
  # Keep the scheduled-post queue full enough to hit the goal's cadence.
  #
  # A failed render HALTS the tick -- it is no longer rotated across pillars. That
  # rotation existed for one reason: an NSFW rejection was pillar-specific (a
  # lingerie-drifted fashion render said nothing about the cooking pillar), so a
  # rejected pillar was worth retrying with another. As of PRD 0007 A1 the classifier
  # is a MEASUREMENT, not a veto, so no render failure is pillar-specific any more --
  # what is left is render/infrastructure failure and the realism veto, both
  # model-wide, and the correct response to a model-wide fault is to stop and let the
  # brain escalate rather than to spend the tick re-rolling pillars.
  class CadenceEngine
    LOOKAHEAD_DAYS = 7
    # Minimum lead for a freshly generated post. The exact slot is allocated by
    # Growth::PostSlotPlanner (earliest under-cap day, spaced inside the posting
    # window) -- passing an INCREMENTING lead here is what used to push each
    # successive post a day further out and break the 7-day target window.
    MIN_LEAD_DAYS = 1

    # A render's measured wall-clock cost (three production renders on
    # 2026-09-21: 174s / 295s / 412s). Used ONLY to decide whether the NEXT
    # render fits the caller's budget.
    #
    # WHY A BUDGET EXISTS: the growth tick runs this producer in the FOREGROUND
    # of a timed tool call, and the tick's budget is smaller than a multi-render
    # shortfall (measured: a ~45 min 5-render shortfall inside a 180s budget).
    # The producer was therefore SIGKILLed mid-render, leaving a run no post was
    # ever made from -- later recovered by RenderSalvage, but the tick's work was
    # wasted and the queue kept a hole. Bounding the work to what fits means the
    # producer stops after the renders that fit, releases the GPU at the end of
    # the tick, and the NEXT tick tops up the remainder (sync counts existing
    # posts, so a partial run is safe to resume).
    #
    # READ THIS BEFORE "CORRECTING" THE CONSTANT (2026-09-22). The name promises
    # the measured render time; the value is NOT it, and must not be raised to
    # it. The tick's foreground tool call is SIGKILLed at ~420s whatever timeout
    # is requested, while a reserve-vram render now measures 400-720s (ComfyuiJob
    # 7568 414s, 7569 402s, 7570 723s -- 35-step + 25-step flux stages at 1024px),
    # so NO render fits a 360s budget: raising this to the measured figure makes
    # the guard refuse every render and content production stops dead. The guard
    # is deliberately optimistic and its job is now only to bound renders-per-tick
    # at one; the kill it cannot prevent is HARMLESS by design, because the render
    # itself is executed by ComfyUI (a separate process) and the abandoned PNG is
    # turned into a post by Growth::RenderSalvage -- driven GPU-free by
    # Growth::AbandonedRenderWorker every 5 min and by the next tick's sync.
    # What the guard must never do is start work whose ARTIFACT cannot be
    # recovered; keep the salvage path armed when touching this.
    MEASURED_RENDER_SECONDS = 300

    attr_reader :goal

    def initialize(goal:, budget_seconds: nil, clock: nil)
      @goal = goal
      @budget_seconds = budget_seconds&.to_i
      @clock = clock || -> { Time.current }
    end

    def sync
      started_at = @clock.call
      target = posts_target
      existing = scheduled_posts_count

      # FIRST recover renders a killed producer abandoned (see RenderSalvage):
      # paid-for GPU work that never became a post is queue content, and it is
      # cheaper to finish it than to render a replacement. Never budgeted: this
      # path needs no GPU and is bounded by the shortfall.
      salvage = salvage_abandoned_render(existing, target)
      existing = scheduled_posts_count if salvage[:recovered].positive?

      shortfall = [ target - existing, 0 ].max

      if shortfall.zero?
        return { created: 0, target: target, existing: existing, shortfall: 0, salvage: salvage,
                 library: nil, budget_exhausted: false, elapsed_seconds: elapsed(started_at) }
      end

      created = 0
      failures = []
      budget_stopped = false
      config = weighted_pillar_order

      while shortfall > 0 && config.any?
        # Check BEFORE starting a render: a render begun with too little budget
        # left is the kill this exists to avoid.
        if budget_exhausted?(started_at)
          budget_stopped = true
          break
        end

        result = generate_fresh(MIN_LEAD_DAYS, config.shift)

        if result[:success]
          created += 1
          shortfall -= 1
        else
          # One failure ends the tick's fresh-render work. Nothing here is
          # pillar-specific any more (see the class comment), so retrying the slot
          # with a different pillar would only spend GPU time on a fault that is not
          # about the pillar -- the brain escalates on the recorded blockage instead.
          failures << "#{result[:error] || 'unknown'} (run #{result[:run_id]})"
          break
        end
      end

      log_blockage(failures.first) if failures.any?

      # LAST RESORT, GPU-FREE: the fresh path could not keep the queue at target
      # (a refused/blocked render, an exhausted budget, a dead pillar pool), so
      # spend the render LIBRARY to protect the publish runway. The fallback
      # enforces its OWN threshold (RUNWAY_TRIGGER_H, the same 72h the ops board
      # escalates on, so the lever and the alarm cannot disagree), spends at most
      # MAX_PER_CALL, and is idempotent -- when the runway is healthy this is one
      # query and a no-op, which is exactly why it can sit on the tick's path too
      # (the always-on worker drives it without a GPU: see #top_up_from_library).
      library = top_up_from_library(limit: shortfall)

      {
        created: created,
        target: target,
        existing: existing + created,
        shortfall: shortfall,
        failures: failures,
        salvage: salvage,
        library: library_summary(library),
        budget_exhausted: budget_stopped,
        elapsed_seconds: elapsed(started_at)
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
      shortfall = [ target - existing, 0 ].max
      result = shortfall.zero? ? nil : Growth::RenderSalvage.new(goal: goal).call(limit: shortfall)
      { target: target, existing: existing, shortfall: shortfall, result: result }
    end

    # Spend the render LIBRARY (photos already rendered, never posted) when the
    # publish runway is inside Growth::LibraryFallback::RUNWAY_TRIGGER_H.
    #
    # GPU-FREE, and therefore driven from OUTSIDE #sync as well. WHY: the growth
    # tick SKIPS its whole cadence step when it cannot acquire the 4090 -- the
    # right call for RENDERING, but it also skips every path that needs no GPU at
    # all. That is the exact gating bug that left Growth::RenderSalvage without a
    # driver while three paid-for renders sat unposted for 13h (see
    # #recover_abandoned). The render LIBRARY is the last GPU-free source of
    # publishable content in a drought, so it must not inherit that bug: the
    # always-on 5-minute worker (Growth::AbandonedRenderWorker) calls this
    # directly, with no claim, no scheduler and no render.
    #
    # Failures are swallowed: a fallback must never break the caller it is bolted
    # onto, and Growth::LibraryFallback already fail-closes per photo.
    def top_up_from_library(limit: nil)
      Growth::LibraryFallback.new(goal: goal).call(limit: limit)
    rescue StandardError => e
      Rails.logger.error("Growth::CadenceEngine library top-up failed: #{e.class} - #{e.message}")
      nil
    end

    private

    # Stop BEFORE starting a render that cannot finish inside the caller's
    # budget. A budget of nil (the default) means unbounded, i.e. exactly the
    # behaviour every existing caller had.
    def budget_exhausted?(started_at)
      return false if @budget_seconds.nil? || @budget_seconds <= 0

      elapsed(started_at) + MEASURED_RENDER_SECONDS > @budget_seconds
    end

    def elapsed(started_at)
      (@clock.call - started_at).round
    end

    # Recover renders whose sync producer was killed before the post-actions ran.
    # Bounded by the outstanding shortfall: if the queue is already full there is
    # nothing to recover INTO, and the candidates stay on disk for a later tick.
    # Failures here must never break the sync, so the whole call is rescued.
    def salvage_abandoned_render(existing, target)
      budget = [ target - existing, 0 ].max
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

    # Flatten Growth::LibraryFallback's Result into the plain hash #sync returns,
    # so the tick's output line and the worker's log can both read it without
    # knowing the struct.
    def library_summary(result)
      return nil if result.nil?

      {
        created: result.created, rejected: result.rejected, skipped: result.skipped,
        post_ids: result.post_ids, examined: result.examined, budget: result.budget,
        triggered: result.triggered, runway_hours: result.runway_hours, reason: result.reason
      }
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

    # The current pillars in WEIGHTED-RANDOM order: a pillar's weight is its
    # chance of being tried first, but every pillar stays reachable and a
    # rejection still moves on to the next one.
    #
    # This used to be `pillar_candidates.to_a.shuffle`, which DESTROYED the
    # relation's weight order — so `ContentPillar#weight`, the one knob the
    # weekly review's `reweight_toward_top` moves, had no effect at all on what
    # got rendered: every slot drew a uniform permutation and the content mix
    # stayed flat no matter how the weights were "rebalanced". Weighted
    # sampling without replacement honours the weight while keeping variety.
    def weighted_pillar_order
      remaining = pillar_candidates.to_a
      order = []
      until remaining.empty?
        total = remaining.sum { |p| [ p.weight.to_f, 0.0 ].max }
        if total <= 0
          picked = remaining.sample
        else
          roll = rand * total
          acc = 0.0
          picked = remaining.find { |p| acc += [ p.weight.to_f, 0.0 ].max; acc > roll } || remaining.last
        end
        order << picked
        remaining.delete(picked)
      end
      order
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
