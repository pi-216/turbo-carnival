# frozen_string_literal: true

require "rails_helper"

RSpec.describe Base::NavbarComponent, type: :component do
  it "renders with logo" do
    render_inline(described_class.new) do |navbar|
      navbar.with_logo { "Logo" }
    end

    expect(rendered_content).to include("Logo")
  end

  it "renders navigation items" do
    render_inline(described_class.new) do |navbar|
      navbar.with_item(href: "/home", active: true) { "Home" }
      navbar.with_item(href: "/about") { "About" }
    end

    expect(rendered_content).to include('href="/home"')
    expect(rendered_content).to include("Home")
    expect(rendered_content).to include('href="/about"')
    expect(rendered_content).to include("About")
  end

  it "applies active state to items" do
    render_inline(described_class.new) do |navbar|
      navbar.with_item(href: "/home", active: true) { "Home" }
    end

    expect(rendered_content).to include("border-blue-500")
  end

  it "renders actions slot" do
    render_inline(described_class.new) do |navbar|
      navbar.with_actions { "Actions" }
    end

    expect(rendered_content).to include("Actions")
  end

  it "applies sticky positioning when fixed" do
    render_inline(described_class.new(fixed: true))

    expect(rendered_content).to include("sticky")
  end

  it "does not apply sticky positioning when not fixed" do
    render_inline(described_class.new(fixed: false))

    expect(rendered_content).not_to include("sticky")
  end
end
