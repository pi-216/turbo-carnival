# frozen_string_literal: true

# Reconcile ComfyuiJob rows that ComfyUI no longer knows about.
#
# WHY THIS EXISTS
# JobSubmitterWorker refuses to submit ANY job while `ComfyuiJob.where(status:
# %w[submitted running]).count > 0`, with no age bound and no reconciliation:
#
#   in_flight_count = ComfyuiJob.where(status: %w[submitted running]).count
#   if in_flight_count > 0
#     Rails.logger.info("JobSubmitterWorker: #{in_flight_count} jobs in flight, waiting...")
#     return
#   end
#
# So a single orphaned `submitted` row halts the entire submission pipeline
# permanently. That is exactly how 241 phantom rows froze submission for four
# months (no Sidekiq ran, so nothing ever advanced or reaped them), and it
# recurred on 2026-09-19 when the ComfyUI queue was cleared by hand: the two
# in-flight rows stopped being known to ComfyUI but stayed `submitted`, which
# blocked the OOM-retry job 7542 from ever being submitted.
#
# RULE: a job in submitted/running is genuinely in flight ONLY if ComfyUI still
# knows its prompt id (present in /history or /queue). Anything older than the
# grace period and unknown to ComfyUI is an orphan -> terminal status, so the
# back-pressure lifts. The grace period protects jobs that were submitted
# moments ago and are not yet visible.
module Comfyui
  class ReconcileStaleJobs < GLCommand::Callable
    returns :reconciled

    BASE_URL = ENV.fetch("COMFYUI_BASE_URL", "http://127.0.0.1:8188")
    GRACE = 10.minutes

    def call
      live = comfy_ids("/history") | comfy_ids("/queue")

      stale = ComfyuiJob
              .where(status: %w[submitted running])
              .where("submitted_at < ? OR submitted_at IS NULL", GRACE.ago)

      reconciled = 0
      stale.find_each do |job|
        next if live.include?(job.comfyui_job_id.to_s)

        job.update!(
          status: "failed",
          error_message: "reconciled #{Time.current.utc.iso8601}: ComfyUI no longer knows prompt " \
                         "#{job.comfyui_job_id} (instance restarted or its queue was cleared); " \
                         "released so JobSubmitterWorker back-pressure cannot stall submission"
        )
        reconciled += 1
      end

      context.reconciled = reconciled
      Rails.logger.info("ReconcileStaleJobs: #{reconciled} orphaned job(s) released") if reconciled.positive?
    rescue StandardError => e
      # Never let reconciliation break the poll loop it is protecting.
      Rails.logger.error("ReconcileStaleJobs failed: #{e.class} - #{e.message}")
      context.reconciled = 0
    end

    private

    def comfy_ids(path)
      res = Net::HTTP.get_response(URI("#{BASE_URL}#{path}"))
      return Set.new unless res.is_a?(Net::HTTPSuccess)

      d = JSON.parse(res.body)
      case d
      when Hash
        if d.key?("queue_running") || d.key?("queue_pending")
          ids = Set.new
          (d["queue_running"].to_a + d["queue_pending"].to_a).each do |entry|
            ids << entry[1] if entry.is_a?(Array) && entry[1]
          end
          ids
        else
          Set.new(d.keys)
        end
      else
        Set.new
      end
    rescue StandardError
      Set.new
    end
  end
end
