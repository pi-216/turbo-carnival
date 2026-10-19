require "rails_helper"

RSpec.describe SubmitJob do
  let(:pipeline) { FactoryBot.create(:pipeline) }
  let(:pipeline_run) { FactoryBot.create(:pipeline_run, pipeline: pipeline) }
  let(:pipeline_step) { FactoryBot.create(:pipeline_step, pipeline: pipeline) }
  let(:parent_candidate) { FactoryBot.create(:image_candidate, pipeline_step: pipeline_step, pipeline_run: pipeline_run) }

  let(:job_payload) do
    {
      workflow: { nodes: [ { id: 1, type: "LoadImage" } ] },
      variables: { prompt: "test prompt" },
      output_folder: "/tmp/test"
    }
  end

  let(:comfyui_response) { { job_id: "abc123" } }
  let(:comfyui_client) { instance_double(ComfyuiClient) }

  before do
    allow(ComfyuiClient).to receive(:new).and_return(comfyui_client)
    allow(comfyui_client).to receive(:submit_workflow).and_return(comfyui_response)
  end

  describe "#call" do
    context "with valid parameters" do
      it "creates a ComfyuiJob and submits it" do
        expect do
          described_class.call(
            job_payload: job_payload,
            pipeline_step: pipeline_step,
            pipeline_run: pipeline_run
          )
        end.to change(ComfyuiJob, :count).by(1)

        job = ComfyuiJob.last
        expect(job.status).to eq("submitted")
        expect(job.job_payload).to eq(job_payload.deep_stringify_keys)
        expect(job.comfyui_job_id).to eq("abc123")
      end

      it "submits workflow to ComfyUI API" do
        # The workflow is converted to JSON and back during job variable substitution
        # so we expect the stringified version
        expect(comfyui_client).to receive(:submit_workflow).with(job_payload[:workflow].deep_stringify_keys).and_return(comfyui_response)

        described_class.call(
          job_payload: job_payload,
          pipeline_step: pipeline_step,
          pipeline_run: pipeline_run
        )
      end

      it "updates job with ComfyUI job ID" do
        result = described_class.call(
          job_payload: job_payload,
          pipeline_step: pipeline_step,
          pipeline_run: pipeline_run
        )

        expect(result.comfyui_job.comfyui_job_id).to eq("abc123")
        expect(result.comfyui_job.status).to eq("submitted")
        expect(result.comfyui_job.submitted_at).to be_present
      end

      it "returns the created job" do
        result = described_class.call(
          job_payload: job_payload,
          pipeline_step: pipeline_step,
          pipeline_run: pipeline_run
        )

        expect(result).to be_success
        expect(result.comfyui_job).to be_a(ComfyuiJob)
      end

      it "associates job with pipeline_run and pipeline_step" do
        result = described_class.call(
          job_payload: job_payload,
          pipeline_step: pipeline_step,
          pipeline_run: pipeline_run
        )

        job = result.comfyui_job
        expect(job.pipeline_run).to eq(pipeline_run)
        expect(job.pipeline_step).to eq(pipeline_step)
      end

      it "associates job with parent_candidate when provided" do
        result = described_class.call(
          job_payload: job_payload,
          pipeline_step: pipeline_step,
          pipeline_run: pipeline_run,
          parent_candidate: parent_candidate
        )

        expect(result.comfyui_job.parent_candidate).to eq(parent_candidate)
      end

      it "leaves parent_candidate nil when not provided" do
        result = described_class.call(
          job_payload: job_payload,
          pipeline_step: pipeline_step,
          pipeline_run: pipeline_run
        )

        expect(result.comfyui_job.parent_candidate).to be_nil
      end
    end

    context "when the run is in a terminal status" do
      %w[completed failed].each do |status|
        it "refuses to dispatch a render for a #{status} run" do
          # update_column: skip the run's status-change callback (Turbo broadcast),
          # this example only needs the terminal state in place.
          pipeline_run.update_column(:status, status)

          result = nil
          expect do
            result = described_class.call(
              job_payload: job_payload,
              pipeline_step: pipeline_step,
              pipeline_run: pipeline_run
            )
          end.not_to change(ComfyuiJob, :count)

          expect(result).to be_failure
          expect(result.full_error_message).to include("terminal")
          expect(comfyui_client).not_to have_received(:submit_workflow)
        end
      end
    end

    context "when ComfyUI API fails" do
      before do
        allow(comfyui_client).to receive(:submit_workflow).and_raise(ComfyuiClient::ConnectionError, "Connection failed")
      end

      it "marks job as failed" do
        result = described_class.call(
          job_payload: job_payload,
          pipeline_step: pipeline_step,
          pipeline_run: pipeline_run
        )

        expect(result).to be_failure

        job = ComfyuiJob.last
        expect(job).to be_present
        expect(job.status).to eq("failed")
        expect(job.error_message).to include("Connection failed")
      end
    end

    context "when job creation fails" do
      it "returns failure result" do
        allow(ComfyuiJob).to receive(:create!).and_raise(ActiveRecord::RecordInvalid)

        result = described_class.call(
          job_payload: job_payload,
          pipeline_step: pipeline_step,
          pipeline_run: pipeline_run
        )

        expect(result).to be_failure
      end
    end
  end
end
