# frozen_string_literal: true

require "rails_helper"

RSpec.describe Base::SidebarComponent, type: :component do
  it "renders header slot" do
    render_inline(described_class.new) do |sidebar|
      sidebar.with_header { "Header Content" }
    end

    expect(rendered_content).to include("Header Content")
  end

  it "renders with custom width" do
    render_inline(described_class.new(width: "w-80"))

    expect(rendered_content).to include("w-80")
  end

  it "renders basic structure" do
    render_inline(described_class.new)

    expect(rendered_content).to include("<aside")
    expect(rendered_content).to include("bg-gray-900")
  end
end
