require "rails_helper"
require "sidekiq/api"

RSpec.describe JobSubmitterWorker do
  let(:pipeline) { FactoryBot.create(:pipeline) }
  let(:pipeline_run) { FactoryBot.create(:pipeline_run, pipeline: pipeline) }
  let(:pipeline_step) { FactoryBot.create(:pipeline_step, pipeline: pipeline) }
  let(:parent_candidate) { FactoryBot.create(:image_candidate, pipeline_step: pipeline_step, pipeline_run: pipeline_run) }

  describe "#perform" do
    before do
      allow(Sidekiq::ScheduledSet).to receive(:new).and_return([])
    end

    context "when SelectNextJob returns child_generation mode" do
      let(:select_result) do
        SelectNextJob.build_context(
          mode: :child_generation,
          parent_candidate: parent_candidate,
          next_step: pipeline_step,
          pipeline_run: pipeline_run
        )
      end

      let(:payload_result) do
        BuildJobPayload.build_context(
          job_payload: { workflow: {}, variables: {}, output_folder: "/tmp" }
        )
      end

      before do
        allow(SelectNextJob).to receive(:call).and_return(select_result)
        allow(BuildJobPayload).to receive(:call).and_return(payload_result)
        allow(SubmitJob).to receive(:call).and_return(SubmitJob.build_context)
      end

      it "builds and submits a job" do
        expect(BuildJobPayload).to receive(:call).with(
          pipeline_step: pipeline_step,
          pipeline_run: pipeline_run,
          parent_candidate: parent_candidate
        )

        expect(SubmitJob).to receive(:call).with(
          hash_including(
            pipeline_step: pipeline_step,
            pipeline_run: pipeline_run,
            parent_candidate: parent_candidate
          )
        )

        described_class.new.perform
      end

      it "schedules next run" do
        expect(described_class).to receive(:perform_in).with(10.seconds)

        described_class.new.perform
      end
    end

    context "when SelectNextJob returns base_generation mode" do
      let(:select_result) do
        SelectNextJob.build_context(
          mode: :base_generation,
          parent_candidate: nil,
          next_step: pipeline_step,
          pipeline_run: pipeline_run
        )
      end

      let(:payload_result) do
        BuildJobPayload.build_context(
          job_payload: { workflow: {}, variables: {}, output_folder: "/tmp" }
        )
      end

      before do
        allow(SelectNextJob).to receive(:call).and_return(select_result)
        allow(PipelineRun).to receive(:last).and_return(pipeline_run)
        allow(BuildJobPayload).to receive(:call).and_return(payload_result)
        allow(SubmitJob).to receive(:call).and_return(SubmitJob.build_context)
      end

      it "submits base generation job" do
        expect(SubmitJob).to receive(:call).with(
          hash_including(
            pipeline_step: pipeline_step,
            parent_candidate: nil
          )
        )

        described_class.new.perform
      end
    end

    context "when SelectNextJob returns no_work mode" do
      before do
        allow(SelectNextJob).to receive(:call).and_return(
          SelectNextJob.build_context(mode: :no_work)
        )
      end

      it "does not submit a job" do
        expect(BuildJobPayload).not_to receive(:call)
        expect(SubmitJob).not_to receive(:call)

        described_class.new.perform
      end

      it "still schedules next run" do
        expect(described_class).to receive(:perform_in).with(10.seconds)

        described_class.new.perform
      end
    end

    context "when BuildJobPayload fails" do
      let(:select_result) do
        SelectNextJob.build_context(
          mode: :child_generation,
          parent_candidate: parent_candidate,
          next_step: pipeline_step
        )
      end

      before do
        allow(SelectNextJob).to receive(:call).and_return(select_result)
        allow(BuildJobPayload).to receive(:call).and_return(
          BuildJobPayload.build_context(error: "Failed to build payload")
        )
      end

      it "does not submit job" do
        expect(SubmitJob).not_to receive(:call)

        described_class.new.perform
      end
    end
  end
end
