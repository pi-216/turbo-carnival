# frozen_string_literal: true

# Base button component following Tailwind Plus Catalyst design patterns.
# This is the foundational button component - DO NOT write raw button HTML, use this instead.
#
# @example Primary button
#   <%= render Base::ButtonComponent.new(variant: :primary) do %>
#     Save Changes
#   <% end %>
#
# @example Secondary button with custom classes
#   <%= render Base::ButtonComponent.new(variant: :secondary, class: "mt-4") do %>
#     Cancel
#   <% end %>
#
# @example Button as link
#   <%= render Base::ButtonComponent.new(variant: :outline, href: root_path) do %>
#     Go Home
#   <% end %>
module Base
  class ButtonComponent < ApplicationComponent
    # @param variant [Symbol] the button style variant
    # @param size [Symbol] the button size (:sm, :md, :lg)
    # @param href [String, nil] if provided, renders as <a> tag instead of <button>
    # @param type [String] the button type attribute (button, submit, reset)
    # @param disabled [Boolean] whether the button is disabled
    # @param data [Hash] data attributes for Turbo/Stimulus
    # @param class [String] additional CSS classes to merge
    def initialize(variant: :primary, size: :md, href: nil, type: "button", disabled: false, data: {}, class: "")
      @variant = variant
      @size = size
      @href = href
      @type = type
      @disabled = disabled
      @data = data
      @custom_classes = binding.local_variable_get(:class)
    end

    private

    def tag_name
      @href ? :a : :button
    end

    def tag_options
      options = {
        class: button_classes,
        disabled: (@disabled if tag_name == :button),
        data: @data
      }.compact

      if @href
        options[:href] = @href
      else
        options[:type] = @type
      end

      options
    end

    def button_classes
      base = "inline-flex items-center justify-center gap-2 rounded-lg font-semibold transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 disabled:opacity-50 disabled:cursor-not-allowed"

      size_classes = case @size
      when :sm
        "px-3 py-1.5 text-xs"
      when :md
        "px-4 py-2 text-sm"
      when :lg
        "px-6 py-3 text-base"
      else
        "px-4 py-2 text-sm"
      end

      variant_classes = case @variant
      when :primary
        "bg-blue-600 text-white hover:bg-blue-700 focus-visible:outline-blue-600 dark:bg-blue-500 dark:hover:bg-blue-600"
      when :secondary
        "bg-gray-700 text-white hover:bg-gray-600 focus-visible:outline-gray-700 dark:bg-gray-600 dark:hover:bg-gray-500"
      when :outline
        "border border-gray-300 dark:border-gray-700 bg-transparent text-gray-900 dark:text-white hover:bg-gray-100 dark:hover:bg-gray-800 focus-visible:outline-gray-700"
      when :ghost
        "bg-transparent text-gray-900 dark:text-white hover:bg-gray-100 dark:hover:bg-gray-800 focus-visible:outline-gray-700"
      when :danger
        "bg-red-600 text-white hover:bg-red-700 focus-visible:outline-red-600 dark:bg-red-500 dark:hover:bg-red-600"
      when :warning
        "bg-yellow-600 text-white hover:bg-yellow-700 focus-visible:outline-yellow-600 dark:bg-yellow-500 dark:hover:bg-yellow-600"
      else
        # Default to primary
        "bg-blue-600 text-white hover:bg-blue-700 focus-visible:outline-blue-600 dark:bg-blue-500 dark:hover:bg-blue-600"
      end

      [ base, size_classes, variant_classes, @custom_classes ].join(" ").strip
    end
  end
end
