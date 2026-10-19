# frozen_string_literal: true

# Base card component following Tailwind Plus Catalyst design patterns.
# This is the foundational card component - DO NOT write raw card HTML, use this instead.
#
# @example Basic card with body
#   <%= render Base::CardComponent.new do |c| %>
#     <% c.with_body do %>
#       <p>Card content here</p>
#     <% end %>
#   <% end %>
#
# @example Card with header, body, and footer
#   <%= render Base::CardComponent.new(variant: :elevated) do |c| %>
#     <% c.with_header do %>
#       <h3 class="font-semibold">Card Title</h3>
#     <% end %>
#     <% c.with_body do %>
#       <p>Card content</p>
#     <% end %>
#     <% c.with_footer do %>
#       <%= render Base::ButtonComponent.new(variant: :primary) do %>
#         Action
#       <% end %>
#     <% end %>
#   <% end %>
#
# @example Interactive card (clickable)
#   <%= render Base::CardComponent.new(variant: :interactive, href: persona_path(@persona)) do |c| %>
#     <% c.with_body do %>
#       <h4>Sarah</h4>
#       <p>Fashion & Lifestyle</p>
#     <% end %>
#   <% end %>
module Base
  class CardComponent < ApplicationComponent
    renders_one :header
    renders_one :body
    renders_one :footer

    # @param variant [Symbol] the card style variant
    # @param href [String, nil] if provided, wraps card in link (for interactive variant)
    # @param class [String] additional CSS classes to merge
    # @param html_options [Hash] additional HTML attributes (data, aria, etc.)
    def initialize(variant: :default, href: nil, class: "", **html_options)
      @variant = variant
      @href = href
      @custom_classes = binding.local_variable_get(:class)
      @html_options = html_options
    end

    private

    def wrapper_tag
      @href && @variant == :interactive ? :a : :div
    end

    def wrapper_options
      options = { class: card_classes }
      options[:href] = @href if @href && @variant == :interactive
      options.merge(@html_options)
    end

    def card_classes
      base = "bg-gray-800 rounded-lg overflow-hidden"

      variant_classes = case @variant
      when :default
        "border border-gray-700"
      when :elevated
        "shadow-lg border border-gray-700"
      when :outlined
        "border-2 border-gray-600"
      when :interactive
        "border border-gray-700 shadow-sm hover:shadow-lg transition-shadow cursor-pointer"
      else
        "border border-gray-700"
      end

      [ base, variant_classes, @custom_classes ].join(" ").strip
    end

    def header_classes
      "px-6 py-4 border-b border-gray-700 bg-gray-800"
    end

    def body_classes
      "px-6 py-4"
    end

    def footer_classes
      "px-6 py-4 border-t border-gray-700 bg-gray-800"
    end
  end
end
