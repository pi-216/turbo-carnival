# frozen_string_literal: true

# Base badge component for status indicators, counts, and tags.
# This is the foundational badge component - DO NOT write raw badge HTML, use this instead.
#
# @example Status badge
#   <%= render ::Base::BadgeComponent.new(variant: :success) do %>
#     Active
#   <% end %>
#
# @example Count badge
#   <%= render ::Base::BadgeComponent.new(variant: :primary, size: :sm) do %>
#     3
#   <% end %>
#
# @example Tag badge
#   <%= render ::Base::BadgeComponent.new(variant: :outline) do %>
#     Thanksgiving 2024
#   <% end %>
module Base
  class BadgeComponent < ApplicationComponent
    # @param variant [Symbol] the badge style variant
    # @param size [Symbol] the badge size
    # @param class [String] additional CSS classes to merge
    # @param html_options [Hash] additional HTML attributes (data, aria, etc.)
    def initialize(variant: :default, size: :md, class: "", **html_options)
      @variant = variant
      @size = size
      @custom_classes = binding.local_variable_get(:class)
      @html_options = html_options
    end

    private

    def badge_classes
      base = "inline-flex items-center justify-center font-medium transition-colors"

      size_classes = case @size
      when :sm
        "px-2 py-0.5 text-xs rounded-[--radius-sm]"
      when :md
        "px-2.5 py-0.5 text-sm rounded-[--radius-base]"
      when :lg
        "px-3 py-1 text-base rounded-[--radius-md]"
      else
        "px-2.5 py-0.5 text-sm rounded-[--radius-base]"
      end

      variant_classes = case @variant
      when :default
        "bg-gray-100 text-gray-800 dark:bg-gray-700 dark:text-gray-300"
      when :primary
        "bg-blue-100 text-blue-800 dark:bg-blue-900 dark:text-blue-200"
      when :success
        "bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200"
      when :warning
        "bg-yellow-100 text-yellow-800 dark:bg-yellow-900 dark:text-yellow-200"
      when :danger
        "bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200"
      when :info
        "bg-blue-100 text-blue-800 dark:bg-blue-900 dark:text-blue-200"
      when :outline
        "border border-gray-300 text-gray-700 dark:border-gray-600 dark:text-gray-300"
      else
        "bg-gray-100 text-gray-800 dark:bg-gray-700 dark:text-gray-300"
      end

      [ base, size_classes, variant_classes, @custom_classes ].join(" ").strip
    end
  end
end
