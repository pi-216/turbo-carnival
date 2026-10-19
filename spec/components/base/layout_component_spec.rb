# frozen_string_literal: true

require "rails_helper"

RSpec.describe Base::LayoutComponent, type: :component do
  it "renders navbar slot" do
    render_inline(described_class.new) do |layout|
      layout.with_navbar { "Navbar Content" }
    end

    expect(rendered_content).to include("Navbar Content")
  end

  it "renders sidebar slot" do
    render_inline(described_class.new) do |layout|
      layout.with_sidebar { "Sidebar Content" }
    end

    expect(rendered_content).to include("Sidebar Content")
  end

  it "renders main content slot" do
    render_inline(described_class.new) do |layout|
      layout.with_main { "Main Content" }
    end

    expect(rendered_content).to include("Main Content")
  end

  it "renders footer slot" do
    render_inline(described_class.new) do |layout|
      layout.with_footer { "Footer Content" }
    end

    expect(rendered_content).to include("Footer Content")
  end

  it "applies max-width container by default" do
    render_inline(described_class.new) do |layout|
      layout.with_main { "Content" }
    end

    expect(rendered_content).to include("max-w-7xl")
  end

  it "removes max-width container when full_width is true" do
    render_inline(described_class.new(full_width: true)) do |layout|
      layout.with_main { "Content" }
    end

    expect(rendered_content).not_to include("max-w-7xl")
  end
end
