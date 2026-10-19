# frozen_string_literal: true

# Base textarea component for multi-line text inputs.
# This is the foundational textarea component - DO NOT write raw textarea HTML, use this instead.
#
# @example Basic textarea
#   <%= render Base::TextareaComponent.new(name: "post[content]", placeholder: "Write your post...") %>
#
# @example Textarea with label
#   <%= render Base::TextareaComponent.new(name: "comment[body]", label: "Comment", rows: 4) %>
#
# @example Textarea with error
#   <%= render Base::TextareaComponent.new(
#     name: "post[content]",
#     label: "Post Content",
#     value: @post.content,
#     error: "Content can't be blank"
#   ) %>
module Base
  class TextareaComponent < ApplicationComponent
    # @param name [String] the textarea name attribute
    # @param label [String, nil] optional label text
    # @param value [String, nil] textarea value
    # @param placeholder [String, nil] placeholder text
    # @param rows [Integer] number of visible text rows
    # @param required [Boolean] whether the textarea is required
    # @param disabled [Boolean] whether the textarea is disabled
    # @param error [String, nil] error message to display
    # @param hint [String, nil] help text to display below textarea
    # @param class [String] additional CSS classes for the textarea
    def initialize(
      name:,
      label: nil,
      value: nil,
      placeholder: nil,
      rows: 4,
      required: false,
      disabled: false,
      error: nil,
      hint: nil,
      class: ""
    )
      @name = name
      @label = label
      @value = value
      @placeholder = placeholder
      @rows = rows
      @required = required
      @disabled = disabled
      @error = error
      @hint = hint
      @custom_classes = binding.local_variable_get(:class)
    end

    private

    def textarea_id
      @name.gsub(/[\[\]]/, "_").gsub(/__+/, "_").gsub(/^_|_$/, "")
    end

    def textarea_classes
      base = "w-full px-4 py-2 rounded-lg border transition-colors focus:outline-none focus:ring-2 focus:ring-offset-0 disabled:opacity-50 disabled:cursor-not-allowed resize-y"

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
