# frozen_string_literal: true

module Base
  # @label Layout
  class LayoutComponentPreview < ViewComponent::Preview
    # @label Full Layout
    def full_layout
      render(Base::LayoutComponent.new) do |layout|
        layout.with_navbar do
          render(Base::NavbarComponent.new) do |navbar|
            navbar.with_logo do
              content_tag(:span, "🎨 TurboCarnival", class: "text-xl font-bold text-white")
            end
            navbar.with_item(href: "#", active: true) { "Dashboard" }
            navbar.with_item(href: "#") { "Personas" }
          end
        end

        layout.with_sidebar do
          render(Base::SidebarComponent.new) do |sidebar|
            sidebar.with_section do |section|
              section.with_item(href: "#", active: true, icon: "📊") { "Dashboard" }
              section.with_item(href: "#", icon: "📝") { "Content" }
              section.with_item(href: "#", icon: "⚙️") { "Settings" }
            end
          end
        end

        layout.with_main do
          content_tag(:div, class: "space-y-6") do
            concat content_tag(:h1, "Welcome to TurboCarnival", class: "text-3xl font-bold text-white")
            concat content_tag(:p, "This is the main content area.", class: "text-gray-400")
          end
        end

        layout.with_footer do
          render(Base::FooterComponent.new) do |footer|
            footer.with_bottom do
              content_tag(:p, "© 2025 TurboCarnival", class: "text-center")
            end
          end
        end
      end
    end

    # @label Without Sidebar
    def without_sidebar
      render(Base::LayoutComponent.new) do |layout|
        layout.with_navbar do
          render(Base::NavbarComponent.new) do |navbar|
            navbar.with_logo { content_tag(:span, "🎨 App", class: "text-xl font-bold text-white") }
          end
        end

        layout.with_main do
          content_tag(:h1, "No Sidebar Layout", class: "text-2xl font-bold text-white")
        end
      end
    end

    # @label Full Width
    def full_width
      render(Base::LayoutComponent.new(full_width: true)) do |layout|
        layout.with_navbar do
          render(Base::NavbarComponent.new) do |navbar|
            navbar.with_logo { content_tag(:span, "🎨", class: "text-2xl") }
          end
        end

        layout.with_main do
          content_tag(:div, "Full width content without padding", class: "p-8 text-white")
        end
      end
    end
  end
end
