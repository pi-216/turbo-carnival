# frozen_string_literal: true

# Base alert component for displaying messages, notifications, and alerts.
# This is the foundational alert component - DO NOT write raw alert HTML, use this instead.
#
# @example Success message
#   <%= render Base::AlertComponent.new(variant: :success) do %>
#     Your changes have been saved successfully!
#   <% end %>
#
# @example Error with title
#   <%= render Base::AlertComponent.new(variant: :danger, title: "Error") do %>
#     There was a problem processing your request.
#   <% end %>
#
# @example Dismissible alert
#   <%= render Base::AlertComponent.new(variant: :warning, dismissible: true) do %>
#     Your session will expire in 5 minutes.
#   <% end %>
module Base
  class AlertComponent < ApplicationComponent
    # @param variant [Symbol] the alert style (success, info, warning, danger)
    # @param title [String, nil] optional title text
    # @param dismissible [Boolean] whether the alert can be dismissed
    # @param class [String] additional CSS classes
    def initialize(variant: :info, title: nil, dismissible: false, class: "")
      @variant = variant
      @title = title
      @dismissible = dismissible
      @custom_classes = binding.local_variable_get(:class)
    end

    private

    def alert_classes
      base = "p-4 rounded-lg border flex items-start gap-3"

      variant_classes = case @variant
      when :success
        "bg-green-900 bg-opacity-20 border-green-700 text-green-100"
      when :info
        "bg-blue-900 bg-opacity-20 border-blue-700 text-blue-100"
      when :warning
        "bg-yellow-900 bg-opacity-20 border-yellow-700 text-yellow-100"
      when :danger
        "bg-red-900 bg-opacity-20 border-red-700 text-red-100"
      else
        "bg-gray-900 bg-opacity-20 border-gray-700 text-gray-100"
      end

      [ base, variant_classes, @custom_classes ].join(" ").strip
    end

    def icon
      case @variant
      when :success
        "✓"
      when :info
        "ℹ"
      when :warning
        "⚠"
      when :danger
        "✕"
      else
        "•"
      end
    end

    def icon_classes
      base = "flex-shrink-0 w-5 h-5 rounded-full flex items-center justify-center font-bold text-sm"

      case @variant
      when :success
        "#{base} bg-green-600 text-white"
      when :info
        "#{base} bg-blue-600 text-white"
      when :warning
        "#{base} bg-yellow-600 text-gray-900"
      when :danger
        "#{base} bg-red-600 text-white"
      else
        "#{base} bg-gray-600 text-white"
      end
    end

    def title_classes
      "font-semibold"
    end

    def dismiss_button_classes
      "ml-auto flex-shrink-0 text-current opacity-70 hover:opacity-100 transition-opacity"
    end
  end
end
