class JobSubmitterWorker
  include Sidekiq::Worker

  sidekiq_options queue: :job_submission, retry: 3

  def perform
    # Only block submission if jobs are actively running in ComfyUI (not just pending)
    in_flight_count = ComfyuiJob.where(status: %w[submitted running]).count

    if in_flight_count > 0
      Rails.logger.info("JobSubmitterWorker: #{in_flight_count} jobs in flight, waiting...")
      schedule_next_run
      return
    end

    result = SelectNextJob.call

    case result.mode
    when :child_generation, :base_generation
      submit_job(result)
      schedule_next_run
    when :no_work
      schedule_next_run
    end
  rescue StandardError => e
    Rails.logger.error("JobSubmitterWorker failed: #{e.class} - #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    schedule_next_run
  end

  private

  def submit_job(select_result)
    # Use the pipeline_run from SelectNextJob result
    pipeline_run = select_result.pipeline_run

    payload_result = BuildJobPayload.call(
      pipeline_step: select_result.next_step,
      pipeline_run: pipeline_run,
      parent_candidate: select_result.parent_candidate
    )

    unless payload_result.success?
      Rails.logger.error("BuildJobPayload failed for step #{select_result.next_step.id}: #{payload_result.error}")
      return
    end

    SubmitJob.call(
      job_payload: payload_result.job_payload,
      pipeline_step: select_result.next_step,
      pipeline_run: pipeline_run,
      parent_candidate: select_result.parent_candidate
    )
  end

  def schedule_next_run
    require 'sidekiq/api'

    scheduled_jobs = Sidekiq::ScheduledSet.new.select { |job| job.klass == self.class.name }
    return if scheduled_jobs.any?

    interval = ENV.fetch("COMFYUI_SUBMIT_INTERVAL", 10).to_i
    self.class.perform_in(interval.seconds)
  end
end
