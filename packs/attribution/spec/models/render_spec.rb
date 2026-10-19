# frozen_string_literal: true

require "rails_helper"

RSpec.describe Attribution::Render, type: :model do
  describe "associations" do
    it { should belong_to(:asset).class_name("Attribution::Asset").optional }
    it { should belong_to(:pipeline_run).optional }
    it { should have_many(:prompt_parts).class_name("Attribution::PromptPart").dependent(:destroy) }
    it { should have_many(:loras).class_name("Attribution::Lora").dependent(:destroy) }
    it { should have_many(:assessments).class_name("Attribution::Assessment").dependent(:destroy) }
  end

  describe "the input set is columns, not a blob" do
    # Success criterion 2 of #37: the seed and the checkpoint are columns, not
    # keys inside a jsonb blob.
    it "stores seed and checkpoint as real columns" do
      expect(described_class.column_names).to include("seed", "checkpoint")
      expect(described_class.columns.find { |c| c.name == "seed" }.type).to eq(:integer)
    end

    it "has no jsonb column at all" do
      jsonb = described_class.columns.select { |c| c.sql_type == "jsonb" }

      expect(jsonb.map(&:name)).to be_empty
    end

    # Red line (#38): the assembled prompt is not authoritative, and may not be
    # parsed back into parts. A prompt column here would be that parsed blob.
    it "carries no assembled prompt column" do
      expect(described_class.column_names).not_to include("prompt", "positive_prompt")
    end
  end

  describe "#inputs" do
    # The run's blob deliberately carries DIFFERENT values than the columns: if any input
    # were still read from `variables`, these examples would answer with the decoy.
    let(:run) do
      create(:pipeline_run,
             variables: { "checkpoint" => "WRONG.safetensors", "seed" => 999, "prompt" => "assembled blob" })
    end
    let(:render) { create(:attribution_render, :with_asset, pipeline_run: run) }

    before do
      create(:attribution_prompt_part, render: render, name: "scene", position: 1,
             text: "sunlit bedroom, vertical three-quarter front view")
      create(:attribution_prompt_part, render: render, name: "identity", position: 0,
             text: "sarah1a3, slender, freckles")
      create(:attribution_prompt_part, render: render, name: "wardrobe", position: 2,
             text: "short cream linen apron")
      create(:attribution_lora, render: render, layer: "base",
             name: "pony/sarah1a3_pony_pornmaster_v1.safetensors", strength: 0.8, enabled: true)
      create(:attribution_lora, render: render, layer: "base",
             name: "pony/underboob.safetensors", strength: 0.75, enabled: false)
      create(:attribution_lora, render: render, layer: "face_inpaint",
             name: "flux/sarah1a3.safetensors", strength: 1.0, enabled: true)
    end

    # Success criterion 1 of #37: the full input set is readable without parsing
    # pipeline_runs.variables. The run's blob is deliberately empty here.
    it "answers in full without consulting the run's variables blob" do
      inputs = render.reload.inputs

      expect(inputs[:checkpoint]).to eq("CRPv18_PM25.safetensors")
      expect(inputs[:seed]).to eq(20_261_019)
      expect(inputs[:sampler]).to eq("euler_ancestral")
      expect(inputs[:scheduler]).to eq("karras")
      expect(inputs[:steps]).to eq(125)
      expect(inputs[:cfg]).to eq(5.5)
      expect(inputs[:denoise]).to eq(1.0)
      expect(inputs[:resolution]).to eq("832x1216")
      expect(inputs[:negative]).to eq("score_5, worst quality, low quality")
      expect(inputs[:workflow_sha256]).to eq(Digest::SHA256.hexdigest("turbo_one_step_v2/step1_generate.json"))
      expect(inputs[:workflow_path]).to eq("comfy_workflows/turbo_one_step_v2/step1_generate.json")
      expect(run.reload.variables).to eq({ "checkpoint" => "WRONG.safetensors", "seed" => 999,
                                           "prompt" => "assembled blob" })
    end

    it "returns prompt parts as named fields, in position order" do
      expect(render.reload.inputs[:prompt_parts].keys).to eq(%w[identity scene wardrobe])
      expect(render.inputs[:prompt_parts]["identity"]).to eq("sarah1a3, slender, freckles")
    end

    it "returns the LoRA set with strengths and the on/off flag" do
      expect(render.reload.inputs[:loras]).to eq([
        { name: "pony/sarah1a3_pony_pornmaster_v1.safetensors", layer: "base", strength: 0.8, enabled: true },
        { name: "pony/underboob.safetensors", layer: "base", strength: 0.75, enabled: false },
        { name: "flux/sarah1a3.safetensors", layer: "face_inpaint", strength: 1.0, enabled: true }
      ])
    end

    it "reads an axis that was never recorded as NULL, never as a default" do
      bare = create(:attribution_render, seed: nil, checkpoint: nil, cfg: nil, width: nil, height: nil)

      inputs = bare.inputs

      expect(inputs[:seed]).to be_nil
      expect(inputs[:checkpoint]).to be_nil
      expect(inputs[:cfg]).to be_nil
      expect(inputs[:resolution]).to be_nil
      expect(inputs[:seed]).not_to eq(0)
    end
  end

  describe "renders with unknown attribution" do
    it "does not require an asset, a run, or any recorded input" do
      render = described_class.create!

      expect(render).to be_persisted
      expect(render.asset).to be_nil
      expect(render.pipeline_run).to be_nil
      expect(render.inputs[:checkpoint]).to be_nil
    end
  end
end
