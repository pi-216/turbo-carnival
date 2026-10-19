# frozen_string_literal: true

require "rails_helper"

RSpec.describe Base::TabsComponent, type: :component do
  it "renders tabs" do
    render_inline(described_class.new) do |component|
      component.with_tab(id: "tab1", label: "First", active: true)
      component.with_tab(id: "tab2", label: "Second")
    end

    expect(rendered_content).to include("First")
    expect(rendered_content).to include("Second")
  end

  it "marks active tab" do
    render_inline(described_class.new) do |component|
      component.with_tab(id: "tab1", label: "First", active: true)
      component.with_tab(id: "tab2", label: "Second")
    end

    expect(rendered_content).to include("border-blue-600")
    expect(rendered_content).to include("text-blue-600")
  end
end
