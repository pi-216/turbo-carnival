require "rails_helper"

RSpec.describe ProcessJobResult do
  let(:pipeline) { FactoryBot.create(:pipeline) }
  let(:pipeline_run) { FactoryBot.create(:pipeline_run, pipeline: pipeline, target_folder: "/tmp/test-run") }
  let(:pipeline_step) { FactoryBot.create(:pipeline_step, pipeline: pipeline, name: "Face Fix") }
  let(:parent_candidate) { FactoryBot.create(:image_candidate, pipeline_step: pipeline_step, pipeline_run: pipeline_run, child_count: 2) }

  let(:comfyui_job) do
    FactoryBot.create(
      :comfyui_job,
      :completed,
      pipeline_run: pipeline_run,
      pipeline_step: pipeline_step,
      parent_candidate: parent_candidate,
      result_metadata: {
        "3" => {
          "images" => [ { "filename" => "output_123.png", "subfolder" => "test_subfolder", "type" => "output" } ]
        }
      }
    )
  end

  describe "#call" do
    it "creates ImageCandidate with correct associations" do
      described_class.call(comfyui_job: comfyui_job)

      # The new candidate is the last one created (parent_candidate was created earlier)
      candidate = ImageCandidate.where.not(id: parent_candidate.id).last

      expect(candidate).to be_present
      expect(candidate.pipeline_step).to eq(pipeline_step)
      expect(candidate.pipeline_run).to eq(pipeline_run)
      expect(candidate.parent).to eq(parent_candidate)
      expect(candidate.status).to eq("active")
    end

    it "sets image_path on ImageCandidate to the ComfyUI output path" do
      result = described_class.call(comfyui_job: comfyui_job)

      expected_path = "/mnt/fscache/essdee/ComfyUI/output/test_subfolder/output_123.png"
      expect(result.image_candidate.image_path).to eq(expected_path)
    end

    it "increments parent child_count" do
      initial_count = parent_candidate.child_count

      described_class.call(comfyui_job: comfyui_job)

      expect(parent_candidate.reload.child_count).to eq(initial_count + 1)
    end

    it "links job to created ImageCandidate" do
      result = described_class.call(comfyui_job: comfyui_job)

      expect(comfyui_job.reload.image_candidate).to eq(result.image_candidate)
    end

    it "returns the created ImageCandidate" do
      result = described_class.call(comfyui_job: comfyui_job)

      expect(result).to be_success
      expect(result.image_candidate).to be_a(ImageCandidate)
    end

    context "when job has no parent_candidate" do
      let(:comfyui_job_without_parent) do
        FactoryBot.create(
          :comfyui_job,
          :completed,
          pipeline_run: pipeline_run,
          pipeline_step: pipeline_step,
          parent_candidate: nil,
          result_metadata: {
            "3" => {
              "images" => [ { "filename" => "output_base.png", "subfolder" => "", "type" => "output" } ]
            }
          }
        )
      end

      it "creates ImageCandidate without parent" do
        result = described_class.call(comfyui_job: comfyui_job_without_parent)

        expect(result.image_candidate.parent).to be_nil
      end

      it "does not try to increment parent child_count" do
        expect do
          described_class.call(comfyui_job: comfyui_job_without_parent)
        end.not_to raise_error
      end
    end
  end
end
