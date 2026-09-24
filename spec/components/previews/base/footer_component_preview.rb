# frozen_string_literal: true

module Base
  # @label Footer
  class FooterComponentPreview < ViewComponent::Preview
    # @label Default
    def default
      render(Base::FooterComponent.new) do |footer|
        footer.with_section do |section|
          section.with_title { "Product" }
          section.with_link(href: "#") { "Features" }
          section.with_link(href: "#") { "Pricing" }
          section.with_link(href: "#") { "Changelog" }
        end

        footer.with_section do |section|
          section.with_title { "Company" }
          section.with_link(href: "#") { "About" }
          section.with_link(href: "#") { "Blog" }
          section.with_link(href: "#") { "Careers" }
        end

        footer.with_section do |section|
          section.with_title { "Resources" }
          section.with_link(href: "#") { "Documentation" }
          section.with_link(href: "#") { "API Reference" }
          section.with_link(href: "#") { "Support" }
        end

        footer.with_section do |section|
          section.with_title { "Legal" }
          section.with_link(href: "#") { "Privacy" }
          section.with_link(href: "#") { "Terms" }
          section.with_link(href: "#") { "Security" }
        end

        footer.with_bottom do
          content_tag(:div, class: "flex flex-col sm:flex-row justify-between items-center gap-4") do
            concat content_tag(:p, "© 2025 TurboCarnival. All rights reserved.")
            concat content_tag(:div, class: "flex gap-6") do
              concat link_to("Twitter", "#", class: "hover:text-white transition-colors")
              concat link_to("GitHub", "#", class: "hover:text-white transition-colors")
              concat link_to("LinkedIn", "#", class: "hover:text-white transition-colors")
            end
          end
        end
      end
    end

    # @label Minimal
    def minimal
      render(Base::FooterComponent.new) do |footer|
        footer.with_bottom do
          content_tag(:div, class: "text-center") do
            "© 2025 TurboCarnival. All rights reserved."
          end
        end
      end
    end

    # @label Two Columns
    def two_columns
      render(Base::FooterComponent.new) do |footer|
        footer.with_section do |section|
          section.with_title { "Quick Links" }
          section.with_link(href: "#") { "Home" }
          section.with_link(href: "#") { "Dashboard" }
          section.with_link(href: "#") { "Settings" }
        end

        footer.with_section do |section|
          section.with_title { "Support" }
          section.with_link(href: "#") { "Help Center" }
          section.with_link(href: "#") { "Contact Us" }
        end

        footer.with_bottom do
          content_tag(:p, "Made with ❤️ by the team")
        end
      end
    end
  end
end
