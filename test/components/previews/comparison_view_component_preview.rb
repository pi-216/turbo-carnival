# frozen_string_literal: true

# Preview for ComparisonViewComponent
class ComparisonViewComponentPreview < ViewComponent::Preview
  # @!group Default

  # Default comparison view with two candidates
  def default
    candidate_a = build_candidate("Final Upscale", 4, 1)
    candidate_b = build_candidate("Final Upscale", 4, 2)
    run = build_run

    render ComparisonViewComponent.new(
      candidate_a: candidate_a,
      candidate_b: candidate_b,
      run: run
    )
  end

  # Comparison at different pipeline steps
  def different_steps
    candidate_a = build_candidate("Base Generation", 1, 1)
    candidate_b = build_candidate("Hand Fix", 3, 2)
    run = build_run

    render ComparisonViewComponent.new(
      candidate_a: candidate_a,
      candidate_b: candidate_b,
      run: run
    )
  end

  # @!endgroup

  private

  def build_candidate(step_name, order, id)
    step = OpenStruct.new(name: step_name, order: order)
    OpenStruct.new(
      id: id,
      pipeline_step: step,
      image_path: nil
    )
  end

  def build_run
    OpenStruct.new(id: 1, name: "Sample Run")
  end
end
