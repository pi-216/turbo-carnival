# frozen_string_literal: true

# Base checkbox component for form checkboxes.
# This is the foundational checkbox component - DO NOT write raw checkbox HTML, use this instead.
#
# @example Basic checkbox
#   <%= render Base::CheckboxComponent.new(
#     name: "user[terms]",
#     label: "I agree to the terms and conditions"
#   ) %>
#
# @example Checked checkbox
#   <%= render Base::CheckboxComponent.new(
#     name: "settings[notifications]",
#     label: "Email notifications",
#     checked: true
#   ) %>
#
# @example Checkbox with hint
#   <%= render Base::CheckboxComponent.new(
#     name: "persona[public]",
#     label: "Make this persona public",
#     hint: "Public personas can be discovered by other users",
#     checked: @persona.public?
#   ) %>
module Base
  class CheckboxComponent < ApplicationComponent
    # @param name [String] the checkbox name attribute
    # @param label [String] label text
    # @param checked [Boolean] whether the checkbox is checked
    # @param disabled [Boolean] whether the checkbox is disabled
    # @param hint [String, nil] help text to display below checkbox
    # @param value [String] the value attribute (default: "1")
    # @param class [String] additional CSS classes
    def initialize(
      name:,
      label:,
      checked: false,
      disabled: false,
      hint: nil,
      value: "1",
      class: ""
    )
      @name = name
      @label = label
      @checked = checked
      @disabled = disabled
      @hint = hint
      @value = value
      @custom_classes = binding.local_variable_get(:class)
    end

    private

    def checkbox_id
      @name.gsub(/[\[\]]/, "_").gsub(/__+/, "_").gsub(/^_|_$/, "")
    end

    def wrapper_classes
      base = "flex items-start gap-3"
      [ @custom_classes, base ].join(" ").strip
    end

    def checkbox_classes
      "w-5 h-5 rounded border-gray-600 bg-gray-700 text-blue-600 focus:ring-2 focus:ring-blue-500 focus:ring-offset-0 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
    end

    def label_classes
      base = "text-sm font-medium text-gray-200"
      disabled = @disabled ? "opacity-50" : ""
      [ base, disabled ].join(" ").strip
    end

    def hint_classes
      "text-sm text-gray-400"
    end
  end
end
