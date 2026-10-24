# frozen_string_literal: true

require "rails_helper"

RSpec.describe Attribution::RecordRender do
  let(:run) { create(:pipeline_run) }
  let(:parts) do
    Attribution::PromptParts.new(
      identity: "sarah1a3, slender, freckles",
      scene: "sunlit bedroom, three-quarter front view",
      wardrobe: "short cream linen apron"
    )
  end

  # #40: a render created now must reference the config version it ran under.
  let(:config_version) do
    Attribution::RecordContentConfigVersion.call(prompt_parts: parts, wardrobe_level: 2).version
  end

  def record(**overrides)
    described_class.call(
      pipeline_run: run,
      prompt_parts: parts,
      content_config_version: config_version,
      checkpoint: "CRPv18_PM25.safetensors",
      seed: 20_261_019,
      steps: 125,
      cfg: 5.5,
      width: 832,
      height: 1216,
      negative_prompt: "score_5, worst quality",
      **overrides
    )
  end

  describe "#call" do
    it "writes the render, its named parts in order, and its LoRA set" do
      result = record(loras: [ { name: "pony/sarah1a3.safetensors", layer: "base", strength: 0.8, enabled: true } ])

      expect(result).to be_success
      render = result.render

      expect(render).to be_persisted
      expect(render.prompt_parts.order(:position).pluck(:name)).to eq(%w[identity scene wardrobe])
      expect(render.loras.pluck(:name, :strength).map { |name, strength| [ name, strength.to_f ] })
        .to eq([ [ "pony/sarah1a3.safetensors", 0.8 ] ])
    end

    # #40 criterion 1: every new render references a version id -- the config's ADDRESS, so a
    # metric shift can be traced to the change that caused it.
    it "links the content config version the render ran under" do
      render = record.render

      expect(render.content_config_version).to eq(config_version)
      expect(render.inputs[:content_config_version]).to eq(config_version.digest)
    end

    it "records two renders of the same config against the same version" do
      first = record(seed: 1).render
      second = record(seed: 2).render

      expect(first.content_config_version).to eq(second.content_config_version)
      expect(Attribution::ContentConfigVersion.count).to eq(1)
    end

    # The run's blob deliberately carries DIFFERENT values: if any input were still read from
    # `variables`, this example would answer with the decoy. The decoy is set at CREATION
    # time, not by an update: a PipelineRun update fires its Turbo broadcast, which is not
    # what this example is about.
    it "answers the attribution question from rows, without the run's variables blob" do
      run = create(:pipeline_run,
                   variables: { "checkpoint" => "WRONG.safetensors", "seed" => 999, "prompt" => "assembled" })
      render = record(pipeline_run: run).render

      expect(render.inputs[:prompt_parts]).to eq(
        "identity" => "sarah1a3, slender, freckles",
        "scene" => "sunlit bedroom, three-quarter front view",
        "wardrobe" => "short cream linen apron"
      )
      expect(render.inputs[:checkpoint]).to eq("CRPv18_PM25.safetensors")
      expect(render.inputs[:negative]).to eq("score_5, worst quality")
      expect(run.reload.variables["prompt"]).to eq("assembled")
    end

    it "leaves an axis nobody passed as NULL, never as a default" do
      render = described_class.call(prompt_parts: parts, content_config_version: config_version).render

      expect(render.seed).to be_nil
      expect(render.checkpoint).to be_nil
      expect(render.cfg).to be_nil
      expect(render.negative_prompt).to be_nil
    end

    it "links the asset by sha256, idempotently" do
      first = record(asset_sha256: "a" * 64, asset_path: "/tmp/a.png").render
      second = record(asset_sha256: "a" * 64).render

      expect(first.asset).to eq(second.asset)
      expect(Attribution::Asset.where(sha256: "a" * 64).count).to eq(1)
    end

    it "updates the render of the same candidate instead of forking a second one" do
      candidate = create(:image_candidate)
      first = record(image_candidate: candidate, asset_sha256: "b" * 64).render
      again = record(image_candidate: candidate, asset_sha256: "b" * 64).render

      expect(again.id).to eq(first.id)
      expect(Attribution::Render.where(image_candidate_id: candidate.id).count).to eq(1)
    end
  end

  describe "what it refuses" do
    it "refuses an assembled prompt in place of the parts" do
      result = described_class.call(pipeline_run: run, prompt_parts: "identity + scene + wardrobe, assembled")

      expect(result).not_to be_success
      expect(result.full_error_message).to match(/NAMED parts/)
      expect(Attribution::Render.count).to eq(0)
    end

    it "refuses an empty part set" do
      result = described_class.call(pipeline_run: run, prompt_parts: {})

      expect(result).not_to be_success
      expect(result.full_error_message).to match(/must name its prompt parts/)
      expect(Attribution::Render.count).to eq(0)
    end

    it "refuses a part name that is not an axis" do
      result = described_class.call(pipeline_run: run, prompt_parts: { "mood" => "cozy" })

      expect(result).not_to be_success
      expect(result.full_error_message).to match(/not a known part/)
      expect(Attribution::Render.count).to eq(0)
    end

    # #40 criterion 1. Same shape as the empty-part refusal above, and for the same reason: a
    # render with no addressable config cannot vote on a config change.
    it "refuses a NEW render that references no content config version" do
      result = described_class.call(pipeline_run: run, prompt_parts: parts)

      expect(result).not_to be_success
      expect(result.full_error_message).to match(/must reference the content config version/)
      expect(Attribution::Render.count).to eq(0)
    end

    # ...and the exemption, so the rule cannot be read as "no render may ever lack a version":
    # filling in an EXISTING row leaves absent attribution absent rather than inventing one.
    it "leaves the version of an existing render alone when a later write omits it" do
      render = record.render

      result = described_class.call(render: render, prompt_parts: parts)

      expect(result).to be_success
      expect(render.reload.content_config_version).to eq(config_version)
    end

    it "refuses to rewrite parts already recorded for a render" do
      render = record.render

      result = described_class.call(render: render,
                                    prompt_parts: Attribution::PromptParts.new(scene: "a different scene"))

      expect(result).not_to be_success
      expect(result.full_error_message).to match(/refusing to rewrite/)
      expect(render.reload.prompt_parts.pluck(:name)).to contain_exactly("identity", "scene", "wardrobe")
      expect(render.prompt_parts.find_by(name: "scene").text).to eq("sunlit bedroom, three-quarter front view")
    end

    # The same facts recorded twice is not a change, and must not read as a failure: a
    # retried write of the same render is the normal case.
    it "is a no-op when the same parts are re-recorded" do
      render = record.render

      result = described_class.call(render: render, prompt_parts: parts)

      expect(result).to be_success
      expect(render.reload.prompt_parts.count).to eq(3)
    end

    it "has no argument for an assembled prompt at all" do
      expect(described_class.arguments).not_to include(:prompt, :positive_prompt, :assembled_prompt)
      expect(described_class.arguments).to include(:prompt_parts)
    end
  end
end
