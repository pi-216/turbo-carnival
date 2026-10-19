# frozen_string_literal: true

# Base input component for form text inputs.
# This is the foundational input component - DO NOT write raw input HTML, use this instead.
#
# @example Basic text input
#   <%= render Base::InputComponent.new(name: "user[email]", type: :email, placeholder: "Enter email") %>
#
# @example Input with label
#   <%= render Base::InputComponent.new(name: "user[name]", label: "Full Name", required: true) %>
#
# @example Input with error
#   <%= render Base::InputComponent.new(
#     name: "user[email]",
#     label: "Email",
#     value: @user.email,
#     error: "Email has already been taken"
#   ) %>
#
# @example Disabled input
#   <%= render Base::InputComponent.new(name: "user[id]", value: @user.id, disabled: true) %>
module Base
  class InputComponent < ApplicationComponent
    # @param name [String] the input name attribute
    # @param type [Symbol] input type (text, email, password, number, tel, url, search)
    # @param label [String, nil] optional label text
    # @param value [String, nil] input value
    # @param placeholder [String, nil] placeholder text
    # @param required [Boolean] whether the input is required
    # @param disabled [Boolean] whether the input is disabled
    # @param error [String, nil] error message to display
    # @param hint [String, nil] help text to display below input
    # @param autocomplete [String, nil] autocomplete attribute
    # @param class [String] additional CSS classes for the input
    def initialize(
      name:,
      type: :text,
      label: nil,
      value: nil,
      placeholder: nil,
      required: false,
      disabled: false,
      error: nil,
      hint: nil,
      autocomplete: nil,
      class: ""
    )
      @name = name
      @type = type
      @label = label
      @value = value
      @placeholder = placeholder
      @required = required
      @disabled = disabled
      @error = error
      @hint = hint
      @autocomplete = autocomplete
      @custom_classes = binding.local_variable_get(:class)
    end

    private

    def input_id
      @name.gsub(/[\[\]]/, "_").gsub(/__+/, "_").gsub(/^_|_$/, "")
    end

    def input_classes
      base = "w-full px-4 py-2 rounded-lg border transition-colors focus:outline-none focus:ring-2 focus:ring-offset-0 disabled:opacity-50 disabled:cursor-not-allowed"

      state_classes = if @error
        "border-red-500 bg-gray-900 text-white focus:border-red-500 focus:ring-red-500"
      else
        "border-gray-600 bg-gray-700 text-white placeholder-gray-400 focus:border-blue-500 focus:ring-blue-500"
      end

      [ base, state_classes, @custom_classes ].join(" ").strip
    end

    def label_classes
      "block text-sm font-medium text-gray-200 mb-2"
    end

    def error_classes
      "mt-2 text-sm text-red-400"
    end

    def hint_classes
      "mt-2 text-sm text-gray-400"
    end
  end
end
