# frozen_string_literal: true

# Base loading component for spinners and loading states.
# This is the foundational loading component - DO NOT write raw spinner HTML, use this instead.
#
# @example Simple spinner
#   <%= render Base::LoadingComponent.new %>
#
# @example Spinner with text
#   <%= render Base::LoadingComponent.new(text: "Loading candidates...") %>
#
# @example Large centered spinner
#   <%= render Base::LoadingComponent.new(size: :lg, text: "Processing images...", centered: true) %>
#
# @example Inline spinner
#   <%= render Base::LoadingComponent.new(size: :sm, variant: :inline) do %>
#     Loading...
#   <% end %>
module Base
  class LoadingComponent < ApplicationComponent
    # @param size [Symbol] spinner size (sm, md, lg)
    # @param text [String, nil] optional loading text
    # @param variant [Symbol] spinner variant (default, inline)
    # @param centered [Boolean] center the spinner
    # @param class [String] additional CSS classes
    def initialize(
      size: :md,
      text: nil,
      variant: :default,
      centered: false,
      class: ""
    )
      @size = size
      @text = text
      @variant = variant
      @centered = centered
      @custom_classes = binding.local_variable_get(:class)
    end

    private

    def wrapper_classes
      base = if @variant == :inline
        "inline-flex items-center gap-2"
      else
        "flex flex-col items-center gap-3"
      end

      centered = @centered ? "justify-center min-h-[200px]" : ""

      [ base, centered, @custom_classes ].join(" ").strip
    end

    def spinner_size
      case @size
      when :sm
        "w-4 h-4"
      when :lg
        "w-12 h-12"
      else # :md
        "w-8 h-8"
      end
    end

    def text_size
      case @size
      when :sm
        "text-sm"
      when :lg
        "text-lg"
      else # :md
        "text-base"
      end
    end
  end
end
