# frozen_string_literal: true

require "rails_helper"

RSpec.describe Base::ModalComponent, type: :component do
  it "renders a modal with default size" do
    render_inline(described_class.new(id: "test-modal", title: "Test")) { "Content" }

    expect(rendered_content).to include('role="dialog"')
    expect(rendered_content).to include("Test")
    expect(rendered_content).to include("Content")
  end

  it "renders a modal with custom size" do
    render_inline(described_class.new(id: "test-modal", size: :lg)) { "Content" }

    expect(rendered_content).to include("max-w-2xl")
  end

  it "renders close button" do
    render_inline(described_class.new(id: "test-modal", title: "Test")) { "Content" }

    expect(rendered_content).to include('button type="button"')
    expect(rendered_content).to include("Close")
  end
end
