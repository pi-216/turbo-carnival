# frozen_string_literal: true

require "rails_helper"

RSpec.describe VotingCardComponent, type: :component do
  let(:pipeline_step) { double("PipelineStep", name: "Final Upscale", order: 4) }
  let(:candidate) { double("ImageCandidate", id: 1, pipeline_step: pipeline_step, image_path: "/path/to/image.png") }
  let(:opponent) { double("ImageCandidate", id: 2, pipeline_step: pipeline_step, image_path: "/path/to/other.png") }
  let(:run) { double("PipelineRun", id: 1) }

  describe "rendering" do
    it "renders the candidate's step name" do
      result = render_inline(VotingCardComponent.new(
        candidate: candidate,
        opponent: opponent,
        run: run,
        position: :left
      ))

      expect(result.to_html).to include("Final Upscale")
      expect(result.to_html).to include("Step 4")
    end

    it "includes a form to vote for the candidate" do
      result = render_inline(VotingCardComponent.new(
        candidate: candidate,
        opponent: opponent,
        run: run,
        position: :left
      ))

      expect(result.to_html).to include('name="winner_id"')
      expect(result.to_html).to include('value="1"')
    end

    it "sets the correct data-voting-target based on position" do
      result = render_inline(VotingCardComponent.new(
        candidate: candidate,
        opponent: opponent,
        run: run,
        position: :right
      ))

      expect(result.to_html).to include('data-voting-target="rightForm"')
    end
  end
end
