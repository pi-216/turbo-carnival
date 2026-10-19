# frozen_string_literal: true

require "rails_helper"

RSpec.describe Base::FooterComponent, type: :component do
  it "renders bottom slot" do
    render_inline(described_class.new) do |footer|
      footer.with_bottom { "© 2025 Company" }
    end

    expect(rendered_content).to include("© 2025 Company")
  end

  it "renders basic structure" do
    render_inline(described_class.new)

    expect(rendered_content).to include("<footer")
    expect(rendered_content).to include("bg-gray-900")
  end
end
