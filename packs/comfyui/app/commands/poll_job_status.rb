class PollJobStatus < GLCommand::Callable
  requires :comfyui_job

  returns :status, :needs_processing

  def call
    job = context.comfyui_job

    response = ComfyuiClient.new.get_job_status(job.comfyui_job_id)

    case response[:status]
    when "running"
      job.update!(status: "running")
      context.status = "running"
      context.needs_processing = false

    when "completed"
      job.update!(
        status: "completed",
        completed_at: Time.current,
        result_metadata: response[:output]
      )
      context.status = "completed"
      context.needs_processing = true

    when "failed"
      job.update!(
        status: "failed",
        error_message: response[:error]
      )
      context.status = "failed"
      context.needs_processing = false

      # OOM is a retryable transient (memory-tight workflow on shared GPU):
      # queue a re-run rather than failing the branch. Only retry when the
      # GPU is actually under contention — never in a tight auto-retry loop.
      if ComfyuiClient.oom_error?(response[:error]) && attempt_oom_retry?
        enqueue_oom_retry(job)
        Rails.logger.warn("OOM for job #{job.id} (#{job.comfyui_job_id}) — queued retry")
      elsif job.parent_candidate
        # Track failure on parent and auto-reject if threshold reached
        parent = job.parent_candidate
        parent.update!(failure_count: parent.failure_count + 1)

        max_failures = ENV.fetch("MAX_PARENT_FAILURES", 3).to_i
        if parent.failure_count >= max_failures
          Rails.logger.warn("Parent #{parent.id} reached #{parent.failure_count} failures - auto-rejecting")
          RejectImageBranch.call(image_candidate: parent)
        end
      end
    end
  rescue StandardError => e
    # Log error but re-raise for caller to handle
    Rails.logger.error("PollJobStatus failed for job #{job.id}: #{e.message}")
    raise
  end

  private

  MAX_OOM_RETRIES = 1

  # Bound OOM retries per pipeline run so a persistently starved GPU can't
  # trigger an endless resubmit loop.
  def attempt_oom_retry?
    oom_retries = context.comfyui_job.pipeline_run.oom_retries || 0
    oom_retries < MAX_OOM_RETRIES
  end

  def enqueue_oom_retry(job)
    run = job.pipeline_run
    run.update!(oom_retries: (run.oom_retries || 0) + 1)

    # SubmitJob creates the record AND posts the workflow to ComfyUI.
    # The previous behaviour created a bare `pending` ComfyuiJob, which nothing
    # ever submits -- JobSubmitterWorker builds NEW jobs via SelectNextJob ->
    # SubmitJob and never sweeps pending ComfyuiJob rows -- so the OOM retry was
    # a silent no-op that stranded a row forever (observed: job 7542 pending
    # since 15:40 with no comfyui_job_id while its run stayed OOM-failed).
    SubmitJob.call(
      job_payload: job.job_payload,
      pipeline_step: job.pipeline_step,
      pipeline_run: run,
      parent_candidate: job.parent_candidate
    )
  end
end
