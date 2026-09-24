# frozen_string_literal: true

require "rails_helper"

RSpec.describe ComparisonViewComponent, type: :component do
  let(:pipeline_step) { double("PipelineStep", name: "Final Upscale", order: 4) }
  let(:candidate_a) { double("ImageCandidate", id: 1, pipeline_step: pipeline_step, image_path: "/a.png") }
  let(:candidate_b) { double("ImageCandidate", id: 2, pipeline_step: pipeline_step, image_path: "/b.png") }
  let(:run) { double("PipelineRun", id: 1) }

  describe "rendering" do
    it "renders voting controller data attribute" do
      result = render_inline(ComparisonViewComponent.new(
        candidate_a: candidate_a,
        candidate_b: candidate_b,
        run: run
      ))

      expect(result.to_html).to include('data-controller="voting"')
    end

    it "includes instructions for keyboard shortcuts" do
      result = render_inline(ComparisonViewComponent.new(
        candidate_a: candidate_a,
        candidate_b: candidate_b,
        run: run
      ))

      expect(result.to_html).to include("← / → arrows to vote")
      expect(result.to_html).to include("K to kill")
      expect(result.to_html).to include("N to skip")
    end

    it "renders both voting cards" do
      result = render_inline(ComparisonViewComponent.new(
        candidate_a: candidate_a,
        candidate_b: candidate_b,
        run: run
      ))

      # Should have two forms, one for each candidate
      expect(result.to_html.scan(/name="winner_id"/).count).to eq(2)
    end

    it "renders kill buttons for both candidates" do
      result = render_inline(ComparisonViewComponent.new(
        candidate_a: candidate_a,
        candidate_b: candidate_b,
        run: run
      ))

      expect(result.to_html).to include("Kill Left Image")
      expect(result.to_html).to include("Kill Right Image")
    end
  end
end
