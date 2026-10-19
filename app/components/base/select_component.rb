# frozen_string_literal: true

# Base select component for dropdown menus.
# This is the foundational select component - DO NOT write raw select HTML, use this instead.
#
# @example Basic select
#   <%= render Base::SelectComponent.new(
#     name: "user[country]",
#     options: [["United States", "us"], ["Canada", "ca"], ["Mexico", "mx"]]
#   ) %>
#
# @example Select with label and prompt
#   <%= render Base::SelectComponent.new(
#     name: "persona[pillar_id]",
#     label: "Content Pillar",
#     prompt: "Select a pillar...",
#     options: @pillars.map { |p| [p.name, p.id] },
#     required: true
#   ) %>
#
# @example Select with error
#   <%= render Base::SelectComponent.new(
#     name: "run[pipeline_id]",
#     label: "Pipeline",
#     options: @pipelines.map { |p| [p.name, p.id] },
#     selected: @run.pipeline_id,
#     error: "Pipeline can't be blank"
#   ) %>
module Base
  class SelectComponent < ApplicationComponent
    # @param name [String] the select name attribute
    # @param options [Array] array of [label, value] pairs or strings
    # @param label [String, nil] optional label text
    # @param selected [String, Integer, nil] currently selected value
    # @param prompt [String, nil] prompt text for first blank option
    # @param required [Boolean] whether the select is required
    # @param disabled [Boolean] whether the select is disabled
    # @param error [String, nil] error message to display
    # @param hint [String, nil] help text to display below select
    # @param multiple [Boolean] allow multiple selections
    # @param class [String] additional CSS classes for the select
    def initialize(
      name:,
      options:,
      label: nil,
      selected: nil,
      prompt: nil,
      required: false,
      disabled: false,
      error: nil,
      hint: nil,
      multiple: false,
      class: ""
    )
      @name = name
      @options = options
      @label = label
      @selected = selected
      @prompt = prompt
      @required = required
      @disabled = disabled
      @error = error
      @hint = hint
      @multiple = multiple
      @custom_classes = binding.local_variable_get(:class)
    end

    private

    def select_id
      @name.gsub(/[\[\]]/, "_").gsub(/__+/, "_").gsub(/^_|_$/, "")
    end

    def select_classes
      base = "w-full px-4 py-2 rounded-lg border transition-colors focus:outline-none focus:ring-2 focus:ring-offset-0 disabled:opacity-50 disabled:cursor-not-allowed"

      state_classes = if @error
        "border-red-500 bg-gray-900 text-white focus:border-red-500 focus:ring-red-500"
      else
        "border-gray-600 bg-gray-700 text-white focus:border-blue-500 focus:ring-blue-500"
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

    def normalize_options
      @options.map do |option|
        if option.is_a?(Array)
          option
        else
          [ option, option ]
        end
      end
    end

    def selected?(value)
      if @multiple
        Array(@selected).include?(value)
      else
        @selected.to_s == value.to_s
      end
    end
  end
end
