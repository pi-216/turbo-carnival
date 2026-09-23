# frozen_string_literal: true

module Growth
  # GPU-FREE recovery of renders a killed producer abandoned, on its own loop.
  #
  # WHY THIS EXISTS (root cause, 2026-09-22): a sync producer that the caller's
  # tool-call ceiling SIGKILLs leaves its run non-terminal with the PNG already
  # on disk and no post. Growth::RenderSalvage recovers exactly that -- and it
  # needs NO GPU (it only re-reads an image already written to output/), which
  # is why it was extracted as Growth::CadenceEngine#recover_abandoned.
  #
  # But its only driver was the TOP of #sync, and the growth tick never reaches
  # #sync when it cannot acquire the 4090. Measured: while a foreign claim held
  # the card 19:00-22:00 EDT on 2026-09-21, no tick salvaged and two paid-for
  # renders sat unrecovered; on 2026-09-19 three of them sat on disk 13h+ while
  # the queue drained. Recovery must not be gated on the claim.
  #
  # Bounded (the cadence shortfall caps it), idempotent (a Photo row for the
  # path is the marker), and self-rescheduling, so it runs on the same pattern
  # as JobPollerWorker -- in the always-on worker, not in a GPU-acquiring tick.
  # Only an ACTIVE goal is served, so a closed/halted goal is never posted to.
  #
  # FILE LOCATION IS LOAD-BEARING -- do not move this into app/workers/. A pack
  # `app/*` directory that did not exist when a process booted is NOT in that
  # process's Zeitwerk roots (roots are globbed once, at boot; Zeitwerk's reload
  # re-scans the registered roots but never adds one), so the running worker
  # cannot resolve the constant it schedules: measured 2026-09-21, where a
  # sidekiq booted 09-19 13:23 threw `NameError: uninitialized constant
  # Growth::AbandonedRenderWorker` on every attempt and left the recovery loop
  # unarmed until a human restarted it. Placed in app/services/growth/, whose
  # root predates that boot, the class resolves through the dev reloader with NO
  # restart. Sidekiq constantizes the class INSIDE the Rails reloader
  # (sidekiq-7.3.9 processor.rb:139-141), which is what makes that work.
  #
  # It is the GPU-FREE QUEUE-LIQUIDITY loop, not just a salvage timer: each tick
  # recovers abandoned renders AND, when the queue is still short, spends the
  # render library (CadenceEngine#top_up_from_library). Both steps need no GPU,
  # both are idempotent, and both exist for the same reason -- they must run
  # during a GPU hold, when the growth tick (which requires the 4090) skips its
  # entire cadence step. Adding a second step did NOT change the class name,
  # deliberately: the armed Sidekiq schedule holds the class NAME, so a rename
  # would silently un-arm the loop until a restart.
  class AbandonedRenderWorker
    include Sidekiq::Worker

    sidekiq_options queue: :default, retry: 3

    # Every 5 min matches the abandonment grace (RenderSalvage::ABANDONED_AFTER
    # = 30 min) closely enough that a killed producer's render becomes a queued
    # post within ~35 min instead of waiting for the next GPU-acquiring tick.
    INTERVAL_SECONDS = ENV.fetch('GROWTH_SALVAGE_INTERVAL', 300).to_i

    def perform
      goal = Growth::Goal.active.first
      if goal && INTERVAL_SECONDS.positive?
        engine = Growth::CadenceEngine.new(goal: goal)
        outcome = engine.recover_abandoned
        recovered = outcome[:result]&.recovered.to_i
        Rails.logger.info("Growth::AbandonedRenderWorker: recovered=#{recovered} #{outcome.inspect}") if recovered.positive?

        # SECOND GPU-FREE STEP: recovery is bounded by the cadence shortfall, so a
        # shortfall still open after it means the queue is short and the fresh
        # path is not filling it (blocked render / blocked claim / a dead pillar
        # pool). That is precisely when the render LIBRARY is the only remaining
        # source of publishable content -- and it is the step that used to have
        # NO DRIVER: it was reachable only by a hand-run rake task, so a recorded
        # plan ("spend the library when the runway crosses 72h") had no executor
        # in the drought it was written for. The fallback re-checks the runway
        # trigger itself (and no-ops above 72h), so this call is safe on every
        # tick, whether or not a drought is on.
        library = outcome[:shortfall].to_i.positive? ? engine.top_up_from_library : nil
        if library&.created.to_i.positive?
          Rails.logger.warn("Growth::AbandonedRenderWorker: spent #{library.created} library photo(s) " \
                            "into posts #{library.post_ids.inspect} (runway was #{library.runway_hours}h)")
        end
      end
    rescue StandardError => e
      # A recovery failure must never kill the loop: the next tick retries and
      # the candidates stay on disk either way.
      Rails.logger.error("Growth::AbandonedRenderWorker failed: #{e.class} - #{e.message}")
    ensure
      schedule_next_run
    end

    private

    def schedule_next_run
      return if INTERVAL_SECONDS <= 0

      require 'sidekiq/api'
      already_scheduled = Sidekiq::ScheduledSet.new.any? { |job| job.klass == self.class.name }
      return if already_scheduled

      self.class.perform_in(INTERVAL_SECONDS)
    end
  end
end
