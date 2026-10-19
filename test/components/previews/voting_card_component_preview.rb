# frozen_string_literal: true

# Preview for VotingCardComponent
class VotingCardComponentPreview < ViewComponent::Preview
  # @!group Default

  # Default voting card with sample data
  def default
    candidate = build_candidate("Final Upscale", 4)
    opponent = build_candidate("Final Upscale", 4)
    run = build_run

    render VotingCardComponent.new(
      candidate: candidate,
      opponent: opponent,
      run: run,
      position: :left
    )
  end

  # Voting card for base step
  def base_step
    candidate = build_candidate("Base Generation", 1)
    opponent = build_candidate("Base Generation", 1)
    run = build_run

    render VotingCardComponent.new(
      candidate: candidate,
      opponent: opponent,
      run: run,
      position: :left
    )
  end

  # @!endgroup

  private

  def build_candidate(step_name, order)
    step = OpenStruct.new(name: step_name, order: order)
    OpenStruct.new(
      id: rand(1000),
      pipeline_step: step,
      image_path: nil
    )
  end

  def build_run
    OpenStruct.new(id: 1, name: "Sample Run")
  end
end
