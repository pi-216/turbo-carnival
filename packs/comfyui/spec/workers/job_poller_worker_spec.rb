require "rails_helper"
require "sidekiq/api"

RSpec.describe JobPollerWorker do
  let(:completed_job) { FactoryBot.create(:comfyui_job, :completed) }
  let(:running_job) { FactoryBot.create(:comfyui_job, :running) }
  let(:submitted_job) { FactoryBot.create(:comfyui_job, :submitted) }

  describe "#perform" do
    before do
      allow(Sidekiq::ScheduledSet).to receive(:new).and_return([])
    end

    context "when jobs are in-flight" do
      before do
        running_job
        submitted_job
      end

      it "polls all in-flight jobs" do
        expect(PollJobStatus).to receive(:call).exactly(2).times.and_return(
          PollJobStatus.build_context(status: "running", needs_processing: false)
        )

        described_class.new.perform
      end

      it "schedules next run" do
        allow(PollJobStatus).to receive(:call).and_return(
          PollJobStatus.build_context(status: "running", needs_processing: false)
        )

        expect(described_class).to receive(:perform_in).with(5.seconds)

        described_class.new.perform
      end
    end

    context "when a job completes" do
      before do
        running_job
      end

      it "processes the result" do
        allow(PollJobStatus).to receive(:call).and_return(
          PollJobStatus.build_context(status: "completed", needs_processing: true)
        )

        expect(ProcessJobResult).to receive(:call).with(comfyui_job: running_job)

        described_class.new.perform
      end
    end

    context "when a job is still running" do
      before do
        running_job
      end

      it "does not process the result" do
        allow(PollJobStatus).to receive(:call).and_return(
          PollJobStatus.build_context(status: "running", needs_processing: false)
        )

        expect(ProcessJobResult).not_to receive(:call)

        described_class.new.perform
      end
    end

    context "when polling fails" do
      before do
        running_job
      end

      it "logs error and continues" do
        allow(PollJobStatus).to receive(:call).and_raise(StandardError, "API error")
        allow(Rails.logger).to receive(:error)

        expect(Rails.logger).to receive(:error).with(/JobPollerWorker failed/)

        expect do
          described_class.new.perform
        end.not_to raise_error
      end

      it "still schedules next run" do
        allow(PollJobStatus).to receive(:call).and_raise(StandardError, "API error")
        allow(Rails.logger).to receive(:error)

        expect(described_class).to receive(:perform_in).with(5.seconds)

        described_class.new.perform
      end
    end

    context "when no jobs are in-flight" do
      it "does nothing but schedules next run" do
        expect(PollJobStatus).not_to receive(:call)
        expect(described_class).to receive(:perform_in).with(5.seconds)

        described_class.new.perform
      end
    end
  end
end
