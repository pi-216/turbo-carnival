# frozen_string_literal: true

require "rails_helper"

RSpec.describe Base::TooltipComponent, type: :component do
  it "renders tooltip with text" do
    render_inline(described_class.new(text: "Helpful tip")) { "Hover me" }

    expect(rendered_content).to include("Hover me")
    expect(rendered_content).to include("Helpful tip")
  end

  it "positions tooltip at top by default" do
    render_inline(described_class.new(text: "Tip")) { "Content" }

    expect(rendered_content).to include("bottom-full")
  end

  it "positions tooltip at specified location" do
    render_inline(described_class.new(text: "Tip", position: :right)) { "Content" }

    expect(rendered_content).to include("left-full")
  end
end
