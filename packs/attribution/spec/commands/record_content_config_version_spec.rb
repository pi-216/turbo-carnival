# frozen_string_literal: true

require "rails_helper"

RSpec.describe Attribution::RecordContentConfigVersion do
  let(:parts) do
    Attribution::PromptParts.new(
      identity: "sarah1a3, slender, freckles",
      scene: "sunlit bedroom, three-quarter front view",
      wardrobe: "short cream linen apron"
    )
  end

  def record(**overrides)
    described_class.call(
      prompt_parts: parts,
      wardrobe_level: 2,
      checkpoint: "CRPv18_PM25.safetensors",
      negative_prompt: "score_5, worst quality",
      workflow_sha256: Digest::SHA256.hexdigest("turbo_one_step_v2/step1_generate.json"),
      workflow_path: "comfy_workflows/turbo_one_step_v2/step1_generate.json",
      **overrides
    )
  end

  describe "#call" do
    it "writes the version, its named parts in order, and its LoRA set" do
      result = record(loras: [ { name: "pony/sarah1a3.safetensors", layer: "base", strength: 0.8, enabled: true } ])

      expect(result).to be_success
      version = result.version

      expect(version).to be_persisted
      expect(version.checkpoint).to eq("CRPv18_PM25.safetensors")
      expect(version.wardrobe_level).to eq(2)
      expect(version.prompt_parts.order(:position).pluck(:name)).to eq(%w[identity scene wardrobe])
      expect(version.loras.pluck(:name)).to eq([ "pony/sarah1a3.safetensors" ])
      expect(version).to be_consistent
    end

    # Content-addressed, like `Attribution::Asset`: the same config is the same row however
    # often it is recorded, so a retried tick or a second render of the same scene cannot fork
    # the version it is meant to be attributed to.
    it "resolves the same pins to the same row instead of forking a version" do
      first = record.version
      again = record.version

      expect(again.id).to eq(first.id)
      expect(Attribution::ContentConfigVersion.count).to eq(1)
    end

    it "writes a NEW version when a pin changes, never an edit of the old one" do
      first = record.version
      changed = record(checkpoint: "a-different.safetensors").version

      expect(changed.id).not_to eq(first.id)
      expect(first.reload.checkpoint).to eq("CRPv18_PM25.safetensors")
      expect(first.prompt_parts.pluck(:text)).to eq(parts.to_h.values)
    end

    it "links the pillar it configures and the step whose graph it pins" do
      pillar = create(:content_pillar, persona: create(:persona))
      step = create(:pipeline_step)

      version = record(content_pillar: pillar, pipeline_step: step).version

      expect(version.content_pillar).to eq(pillar)
      expect(version.pipeline_step).to eq(step)
    end
  end

  describe "what it refuses" do
    it "refuses an assembled prompt in place of the parts" do
      result = described_class.call(prompt_parts: "identity + scene + wardrobe, assembled")

      expect(result).not_to be_success
      expect(result.full_error_message).to match(/NAMED parts/)
      expect(Attribution::ContentConfigVersion.count).to eq(0)
    end

    it "refuses an empty part set" do
      result = described_class.call(prompt_parts: {})

      expect(result).not_to be_success
      expect(result.full_error_message).to match(/must name its prompt parts/)
      expect(Attribution::ContentConfigVersion.count).to eq(0)
    end

    it "refuses a part name that is not an axis" do
      result = described_class.call(prompt_parts: { "mood" => "cozy" })

      expect(result).not_to be_success
      expect(result.full_error_message).to match(/not a known part/)
      expect(Attribution::ContentConfigVersion.count).to eq(0)
    end

    it "has no argument for an assembled prompt at all" do
      expect(described_class.arguments).not_to include(:prompt, :positive_prompt, :assembled_prompt)
      expect(described_class.arguments).to include(:prompt_parts)
    end
  end
end
