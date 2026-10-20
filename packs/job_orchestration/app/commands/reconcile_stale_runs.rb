# frozen_string_literal: true

# Reconcile PipelineRun rows that a SYNCHRONOUS producer abandoned mid-flight.
#
# WHY THIS EXISTS
# Growth::ContentGenerator creates a run, submits its own ComfyuiJob and polls it
# to completion (it tags the run with variables['sync_producer'] so the async
# dispatcher leaves it alone — see SelectNextJob). Its final act is finish_run,
# which writes the terminal status on every exit path *inside the process*.
#
# That is not enough when the process is killed from outside. The growth tick
# runs inside a cron tool call with a foreground timeout, so a render that takes
# longer than the tick's budget gets SIGKILLed at an arbitrary point — the render
# itself finishes (ComfyuiJob -> completed, ImageCandidate created) but nothing
# ever writes the run's terminal status. Observed 2026-09-19: run 471, created
# 17:01:15Z by the 13:01 tick, job 7555 completed 17:04:53Z, run still `pending`
# an hour later. Nothing re-drives it (SelectNextJob skips sync-produced runs by
# design), so it sits in the workable set forever and every board/stuck-run probe
# reports it as stuck. The same shape produced the batch of 42 `pending` runs
# reconciled by hand earlier the same day.
#
# RULE: a sync-produced run is genuinely in flight only while one of its jobs is
# non-terminal. Once every job is terminal and the run has not moved for the
# grace period, the producer is gone and the run is debris -> `failed` with the
# reason recorded, so it leaves the workable set and the probes go quiet.
#
# `failed` (not `completed`) is deliberate: the producer may have died before
# importing/captioning/scheduling, so claiming completion would assert an outcome
# we cannot see — and `completed` fires link_winner_to_pillar_if_completed, which
# would link a winner for a run whose post may never have been created. The
# render is not lost either way: it survives as an ImageCandidate.
#
# Scope is deliberately narrow: ONLY runs carrying the sync_producer tag. An
# async run with all jobs terminal is normal mid-pipeline state (the dispatcher
# owes it a next step), so reaping it would destroy live work.
class ReconcileStaleRuns < ApplicationCommand
  returns :reconciled

  GRACE = 30.minutes
  OPEN_STATUSES = %w[pending running].freeze
  LIVE_JOB_STATUSES = %w[pending submitted running].freeze
  SYNC_PRODUCER_KEY = "sync_producer"

  def call
    reconciled = 0

    stale_runs.find_each do |run|
      next if ComfyuiJob.where(pipeline_run_id: run.id, status: LIVE_JOB_STATUSES).exists?

      run.update!(
        status: "failed",
        reject_reason: "reconciled #{Time.current.utc.iso8601}: sync producer " \
                       "#{run.variables[SYNC_PRODUCER_KEY]} left this run non-terminal with no job in " \
                       "flight (the producer process was killed before it wrote a terminal status); " \
                       "released so it leaves the workable set"
      )
      reconciled += 1
    end

    context.reconciled = reconciled
    Rails.logger.info("ReconcileStaleRuns: #{reconciled} abandoned sync run(s) released") if reconciled.positive?
  rescue StandardError => e
    # Never let reconciliation break the poll loop it exists to protect.
    Rails.logger.error("ReconcileStaleRuns failed: #{e.class} - #{e.message}")
    context.reconciled = 0
  end

  private

  def stale_runs
    PipelineRun
      .where(status: OPEN_STATUSES)
      .where("(pipeline_runs.variables ->> :key) IS NOT NULL", key: SYNC_PRODUCER_KEY)
      .where("pipeline_runs.updated_at < ?", GRACE.ago)
  end
end
