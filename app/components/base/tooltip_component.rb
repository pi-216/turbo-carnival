# frozen_string_literal: true

class Base::TooltipComponent < ViewComponent::Base
  attr_reader :text, :position

  def initialize(text:, position: :top, **html_options)
    @text = text
    @position = position
    @html_options = html_options
  end

  def wrapper_classes
    [
      "group relative inline-block",
      @html_options[:class]
    ].compact.join(" ")
  end

  def tooltip_classes
    base = "pointer-events-none absolute z-50 hidden rounded-lg bg-zinc-900 px-3 py-2 text-xs text-white shadow-lg group-hover:block"

    position_class = case @position
    when :top
      "bottom-full left-1/2 mb-2 -translate-x-1/2"
    when :bottom
      "top-full left-1/2 mt-2 -translate-x-1/2"
    when :left
      "right-full top-1/2 mr-2 -translate-y-1/2"
    when :right
      "left-full top-1/2 ml-2 -translate-y-1/2"
    else
      "bottom-full left-1/2 mb-2 -translate-x-1/2"
    end

    "#{base} #{position_class}"
  end

  def arrow_classes
    base = "absolute h-2 w-2 rotate-45 bg-zinc-900"

    arrow_position = case @position
    when :top
      "top-full left-1/2 -mt-1 -translate-x-1/2"
    when :bottom
      "bottom-full left-1/2 -mb-1 -translate-x-1/2"
    when :left
      "left-full top-1/2 -ml-1 -translate-y-1/2"
    when :right
      "right-full top-1/2 -mr-1 -translate-y-1/2"
    else
      "top-full left-1/2 -mt-1 -translate-x-1/2"
    end

    "#{base} #{arrow_position}"
  end
end
