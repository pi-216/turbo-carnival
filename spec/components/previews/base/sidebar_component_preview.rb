# frozen_string_literal: true

module Base
  # @label Sidebar
  class SidebarComponentPreview < ViewComponent::Preview
    # @label Default
    def default
      render(Base::SidebarComponent.new) do |sidebar|
        sidebar.with_header do
          content_tag(:div, class: "flex items-center gap-3") do
            concat content_tag(:div, "👤", class: "text-2xl")
            concat content_tag(:div) do
              concat content_tag(:div, "John Doe", class: "text-sm font-medium text-white")
              concat content_tag(:div, "@johndoe", class: "text-xs text-gray-400")
            end
          end
        end

        sidebar.with_section do |section|
          section.with_title { "Main" }
          section.with_item(href: "#", active: true, icon: "📊") { "Dashboard" }
          section.with_item(href: "#", icon: "📝") { "Content Strategy" }
          section.with_item(href: "#", icon: "⚙️") { "Generation" }
        end

        sidebar.with_section do |section|
          section.with_title { "Settings" }
          section.with_item(href: "#", icon: "🔧") { "Configuration" }
          section.with_item(href: "#", icon: "🔗") { "Integrations" }
        end
      end
    end

    # @label Minimal
    def minimal
      render(Base::SidebarComponent.new) do |sidebar|
        sidebar.with_section do |section|
          section.with_item(href: "#", active: true) { "Home" }
          section.with_item(href: "#") { "Settings" }
          section.with_item(href: "#") { "Help" }
        end
      end
    end
  end
end
