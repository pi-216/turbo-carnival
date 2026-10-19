require "rails_helper"

RSpec.describe BuildJobPayload do
  let(:pipeline) { FactoryBot.create(:pipeline) }
  let(:pipeline_run) do
    FactoryBot.create(:pipeline_run,
      pipeline: pipeline,
      prompt: "at the gym",
      target_folder: "/storage/runs/test-run",
      variables: { persona_id: 123, style: "realistic" })
  end

  describe "#call" do
    context "with workflow JSON" do
      it "includes workflow from step" do
        step = FactoryBot.create(:pipeline_step,
          pipeline: pipeline,
          comfy_workflow_json: '{"nodes": ["a", "b"]}')

        result = described_class.call(
          pipeline_step: step,
          pipeline_run: pipeline_run
        )

        expect(result).to be_success
        expect(result.job_payload[:workflow]).to eq({ "nodes" => [ "a", "b" ] })
      end
    end

    context "template variable substitution" do
      it "replaces {{prompt}} in workflow JSON" do
        step = FactoryBot.create(:pipeline_step,
          pipeline: pipeline,
          comfy_workflow_json: '{"prompt": "{{prompt}}"}')

        result = described_class.call(
          pipeline_step: step,
          pipeline_run: pipeline_run
        )

        expect(result).to be_success
        expect(result.job_payload[:workflow]).to eq({ "prompt" => "at the gym" })
      end

      it "replaces {{run_name}} in workflow JSON" do
        run_with_name = FactoryBot.create(:pipeline_run,
          pipeline: pipeline,
          name: "Test Run 123")
        step = FactoryBot.create(:pipeline_step,
          pipeline: pipeline,
          comfy_workflow_json: '{"path": "/output/{{run_name}}/image.png"}')

        result = described_class.call(
          pipeline_step: step,
          pipeline_run: run_with_name
        )

        expect(result).to be_success
        expect(result.job_payload[:workflow]).to eq({ "path" => "/output/Test Run 123/image.png" })
      end

      it "properly escapes newlines in prompt values" do
        run_with_multiline_prompt = FactoryBot.create(:pipeline_run,
          pipeline: pipeline,
          prompt: "Line 1\nLine 2\nLine 3")
        step = FactoryBot.create(:pipeline_step,
          pipeline: pipeline,
          comfy_workflow_json: '{"text": "{{prompt}}"}')

        result = described_class.call(
          pipeline_step: step,
          pipeline_run: run_with_multiline_prompt
        )

        expect(result).to be_success
        expect(result.job_payload[:workflow]).to eq({ "text" => "Line 1\nLine 2\nLine 3" })

        # Verify the workflow can be serialized to valid JSON
        expect { result.job_payload[:workflow].to_json }.not_to raise_error

        # Verify deserializing gives back the same content
        json_str = result.job_payload[:workflow].to_json
        parsed = JSON.parse(json_str)
        expect(parsed["text"]).to eq("Line 1\nLine 2\nLine 3")
      end
    end

    context "with needs_run_prompt" do
      it "includes prompt from run column" do
        step = FactoryBot.create(:pipeline_step,
          pipeline: pipeline,
          needs_run_prompt: true,
          comfy_workflow_json: '{}')

        result = described_class.call(
          pipeline_step: step,
          pipeline_run: pipeline_run
        )

        expect(result.job_payload[:variables][:prompt]).to eq("at the gym")
      end

      it "does not include prompt when flag is false" do
        step = FactoryBot.create(:pipeline_step,
          pipeline: pipeline,
          needs_run_prompt: false,
          comfy_workflow_json: '{}')

        result = described_class.call(
          pipeline_step: step,
          pipeline_run: pipeline_run
        )

        expect(result.job_payload[:variables][:prompt]).to be_nil
      end
    end

    context "with needs_parent_image_path" do
      it "includes parent image path" do
        step = FactoryBot.create(:pipeline_step,
          pipeline: pipeline,
          needs_parent_image_path: true,
          comfy_workflow_json: '{}')
        parent = FactoryBot.create(:image_candidate, image_path: "/images/parent.png")

        result = described_class.call(
          pipeline_step: step,
          pipeline_run: pipeline_run,
          parent_candidate: parent
        )

        expect(result.job_payload[:variables][:parent_image]).to eq("/images/parent.png")
      end

      it "does not include parent path when no parent provided" do
        step = FactoryBot.create(:pipeline_step,
          pipeline: pipeline,
          needs_parent_image_path: true,
          comfy_workflow_json: '{}')

        result = described_class.call(
          pipeline_step: step,
          pipeline_run: pipeline_run
        )

        expect(result.job_payload[:variables][:parent_image]).to be_nil
      end
    end

    context "with needs_run_variables" do
      it "includes all run variables plus prompt" do
        step = FactoryBot.create(:pipeline_step,
          pipeline: pipeline,
          needs_run_variables: true,
          comfy_workflow_json: '{}')

        result = described_class.call(
          pipeline_step: step,
          pipeline_run: pipeline_run
        )

        expect(result.job_payload[:variables][:prompt]).to eq("at the gym")
        expect(result.job_payload[:variables][:persona_id]).to eq(123)
        expect(result.job_payload[:variables][:style]).to eq("realistic")
      end
    end

    context "output folder" do
      it "combines run target_folder with step name" do
        step = FactoryBot.create(:pipeline_step,
          pipeline: pipeline,
          name: "Face Fix",
          comfy_workflow_json: '{}')

        result = described_class.call(
          pipeline_step: step,
          pipeline_run: pipeline_run
        )

        expect(result.job_payload[:output_folder]).to eq("/storage/runs/test-run/face-fix")
      end

      it "handles nil target_folder" do
        run_no_folder = FactoryBot.create(:pipeline_run,
          pipeline: pipeline,
          target_folder: nil,
          variables: {})
        step = FactoryBot.create(:pipeline_step,
          pipeline: pipeline,
          name: "Base",
          comfy_workflow_json: '{}')

        result = described_class.call(
          pipeline_step: step,
          pipeline_run: run_no_folder
        )

        expect(result.job_payload[:output_folder]).to eq("/base")
      end
    end

    context "combined variable requirements" do
      it "includes both prompt and parent when needed" do
        step = FactoryBot.create(:pipeline_step,
          pipeline: pipeline,
          needs_run_prompt: true,
          needs_parent_image_path: true,
          comfy_workflow_json: '{}')
        parent = FactoryBot.create(:image_candidate, image_path: "/images/parent.png")

        result = described_class.call(
          pipeline_step: step,
          pipeline_run: pipeline_run,
          parent_candidate: parent
        )

        expect(result.job_payload[:variables][:prompt]).to eq("at the gym")
        expect(result.job_payload[:variables][:parent_image]).to eq("/images/parent.png")
      end
    end

    # The guard only counts if it is actually IN the render path: every render is
    # submitted through this command, so this asserts the wiring rather than the
    # rules (packs/pipeline/spec/services/pipeline_prompt_safety_spec.rb covers
    # the rules).
    context "prompt safety guard" do
      let(:unsafe_workflow) do
        {
          "79" => { "class_type" => "CLIPTextEncode",
                    "inputs" => { "text" => "worst quality, low quality, adult, mature_face" } },
          "96" => { "class_type" => "KSampler",
                    "inputs" => { "positive" => %w[60 0], "negative" => %w[79 0] } }
        }.to_json
      end

      it "strips adult-suppressing tokens from the sampler's negative prompt" do
        step = FactoryBot.create(:pipeline_step,
          pipeline: pipeline,
          comfy_workflow_json: unsafe_workflow)

        result = described_class.call(pipeline_step: step, pipeline_run: pipeline_run)

        expect(result).to be_success
        expect(result.job_payload[:workflow]["79"]["inputs"]["text"])
          .to eq("worst quality, low quality")
      end

      it "rewrites a minor direction stored in the workflow" do
        legacy = "Change the prompt so the resulting image will be that of a white, " \
                 "Caucasian young teenager. Only return the new prompt."
        step = FactoryBot.create(:pipeline_step,
          pipeline: pipeline,
          comfy_workflow_json: { "1" => { "class_type" => "OllamaGenerateV2",
                                          "inputs" => { "system" => legacy } } }.to_json)

        result = described_class.call(pipeline_step: step, pipeline_run: pipeline_run)

        expect(result).to be_success
        expect(result.job_payload[:workflow]["1"]["inputs"]["system"])
          .to eq("Change the prompt so the resulting image will be that of a white, " \
                 "Caucasian adult. Only return the new prompt.")
      end
    end
  end
end
