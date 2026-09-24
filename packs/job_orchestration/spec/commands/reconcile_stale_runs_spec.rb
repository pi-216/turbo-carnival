require "rails_helper"

RSpec.describe ReconcileStaleRuns do
  let(:pipeline) { FactoryBot.create(:pipeline) }
  let(:step) { FactoryBot.create(:pipeline_step, pipeline: pipeline, order: 1) }

  # A run exactly like the ones Growth::ContentGenerator leaves behind when the
  # cron tick that owns it is SIGKILLed mid-render: tagged as sync-produced, every
  # job terminal, no movement past the grace period.
  def abandoned_sync_run(age: 1.hour, job_status: :terminal)
    run = FactoryBot.create(
      :pipeline_run, pipeline: pipeline, status: "pending",
      variables: { "sync_producer" => "Growth::ContentGenerator" }
    )
    case job_status
    when :terminal
      FactoryBot.create(:comfyui_job, :completed, pipeline_run: run, pipeline_step: step)
    when :in_flight
      FactoryBot.create(:comfyui_job, :submitted, pipeline_run: run, pipeline_step: step)
    end
    run.update_columns(updated_at: age.ago)
    run
  end

  describe "#call" do
    it "releases a sync-produced run whose jobs are all terminal" do
      run = abandoned_sync_run

      result = described_class.call

      expect(result).to be_success
      expect(result.reconciled).to eq(1)
      expect(run.reload.status).to eq("failed")
      expect(run.reject_reason).to include("sync producer")
      expect(run.reject_reason).to include("Growth::ContentGenerator")
    end

    it "leaves a run still inside the grace period alone" do
      run = abandoned_sync_run(age: 1.minute)

      result = described_class.call

      expect(result.reconciled).to eq(0)
      expect(run.reload.status).to eq("pending")
    end

    it "leaves a run alone while one of its jobs is still in flight" do
      run = abandoned_sync_run(job_status: :in_flight)

      result = described_class.call

      expect(result.reconciled).to eq(0)
      expect(run.reload.status).to eq("pending")
    end

    it "leaves an asynchronously dispatched run alone" do
      run = FactoryBot.create(:pipeline_run, pipeline: pipeline, status: "pending")
      FactoryBot.create(:comfyui_job, :completed, pipeline_run: run, pipeline_step: step)
      run.update_columns(updated_at: 2.hours.ago)

      result = described_class.call

      expect(result.reconciled).to eq(0)
      expect(run.reload.status).to eq("pending")
    end

    it "leaves a terminal sync-produced run alone" do
      run = abandoned_sync_run
      run.update_columns(status: "completed")

      result = described_class.call

      expect(result.reconciled).to eq(0)
      expect(run.reload.status).to eq("completed")
    end

    it "never raises out of the poll loop" do
      allow(PipelineRun).to receive(:where).and_raise(StandardError, "db down")

      expect { described_class.call }.not_to raise_error
    end
  end
end
