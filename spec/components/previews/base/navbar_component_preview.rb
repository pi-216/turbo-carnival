# frozen_string_literal: true

module Base
  # @label Navbar
  class NavbarComponentPreview < ViewComponent::Preview
    # @label Default
    def default
      render(Base::NavbarComponent.new) do |navbar|
        navbar.with_logo do
          content_tag(:span, "🎨 TurboCarnival", class: "text-xl font-bold text-white")
        end

        navbar.with_item(href: "#", active: true) { "Dashboard" }
        navbar.with_item(href: "#") { "Personas" }
        navbar.with_item(href: "#") { "Settings" }

        navbar.with_actions do
          render(Base::ButtonComponent.new(variant: :secondary, size: :sm, href: "#")) { "Help" }
        end
      end
    end

    # @label With Multiple Actions
    def with_actions
      render(Base::NavbarComponent.new) do |navbar|
        navbar.with_logo do
          content_tag(:span, "🎨 App", class: "text-xl font-bold text-white")
        end

        navbar.with_item(href: "#", active: true) { "Home" }
        navbar.with_item(href: "#") { "Explore" }

        navbar.with_actions do
          concat render(Base::ButtonComponent.new(variant: :ghost, size: :sm, href: "#")) { "👤 Profile" }
          concat render(Base::ButtonComponent.new(variant: :primary, size: :sm, href: "#")) { "+ New" }
        end
      end
    end

    # @label Minimal
    def minimal
      render(Base::NavbarComponent.new) do |navbar|
        navbar.with_logo do
          content_tag(:span, "Logo", class: "text-white font-bold")
        end
      end
    end
  end
end
