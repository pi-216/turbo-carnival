class JobPollerWorker
  include Sidekiq::Worker

  sidekiq_options queue: :job_polling, retry: 3

  def perform
    # Reconcile orphans FIRST. JobSubmitterWorker refuses to submit while any job
    # is in `submitted`/`running`, so a single phantom row stalls submission
    # indefinitely -- that is what froze the pipeline for four months and what
    # blocked the OOM-retry job on 2026-09-19. See ReconcileStaleJobs.
    ReconcileStaleJobs.call

    # Then the run-level counterpart: a SYNC producer killed mid-render (the
    # growth tick's foreground timeout) leaves its run non-terminal with no job
    # in flight, and nothing else re-drives it. See ReconcileStaleRuns.
    ReconcileStaleRuns.call

    # Poll status of in-flight jobs (may transition to completed)
    in_flight_jobs = ComfyuiJob.in_flight
    in_flight_jobs.find_each do |job|
      poll_and_process(job)
    end

    # Process any completed jobs that haven't been processed yet
    completed_unprocessed = ComfyuiJob.where(status: 'completed', image_candidate_id: nil)
    completed_unprocessed.find_each do |job|
      begin
        ProcessJobResult.call!(comfyui_job: job)
      rescue => e
        Rails.logger.error("Failed to process completed job #{job.id}: #{e.message}")
      end
    end

    schedule_next_run
  end

  private

  def poll_and_process(job)
    result = PollJobStatus.call(comfyui_job: job)

    return unless result.success?

    if result.needs_processing
      ProcessJobResult.call(comfyui_job: job)
    end
  rescue => e
    Rails.logger.error("JobPollerWorker failed for job #{job.id}: #{e.message}")
    Rails.logger.error(e.backtrace.first(5).join("\n"))
  end

  def schedule_next_run
    require 'sidekiq/api'
    
    scheduled_jobs = Sidekiq::ScheduledSet.new.select { |job| job.klass == self.class.name }
    return if scheduled_jobs.any?
    
    interval = ENV.fetch("COMFYUI_POLL_INTERVAL", 5).to_i
    self.class.perform_in(interval.seconds)
  end
end
