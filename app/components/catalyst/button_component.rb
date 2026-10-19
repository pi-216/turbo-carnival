# frozen_string_literal: true

module Catalyst
  # Catalyst Button Component
  #
  # A professional button component with multiple variants and colors.
  # Based on Catalyst UI Kit: https://catalyst.tailwindui.com/docs/button
  #
  # @example Solid button (default)
  #   <%= render Catalyst::ButtonComponent.new(color: :blue) do %>
  #     Save changes
  #   <% end %>
  #
  # @example Outline button
  #   <%= render Catalyst::ButtonComponent.new(variant: :outline) do %>
  #     Cancel
  #   <% end %>
  #
  # @example Plain button
  #   <%= render Catalyst::ButtonComponent.new(variant: :plain) do %>
  #     Learn more
  #   <% end %>
  #
  # @example Danger button
  #   <%= render Catalyst::ButtonComponent.new(color: :red) do %>
  #     Delete
  #   <% end %>
  class ButtonComponent < ApplicationComponent
    def initialize(
      variant: :solid,
      color: :blue,
      size: :default,
      type: "button",
      **attributes
    )
      @variant = variant.to_sym
      @color = color.to_sym
      @size = size.to_sym
      @type = type
      @attributes = attributes
    end

    def call
      tag.button(content, **button_attributes)
    end

    private

    def button_attributes
      @attributes.merge(
        type: @type,
        class: classes
      )
    end

    def classes
      [
        base_classes,
        variant_classes,
        size_classes,
        @attributes[:class]
      ].compact.join(" ")
    end

    def base_classes
      %w[
        relative
        isolate
        inline-flex
        items-baseline
        justify-center
        gap-x-2
        rounded-lg
        border
        font-semibold
        transition-colors
        focus:outline-2
        focus:outline-offset-2
        focus:outline-blue-500
        disabled:opacity-50
        disabled:cursor-not-allowed
      ].join(" ")
    end

    def variant_classes
      case @variant
      when :solid
        solid_variant_classes
      when :outline
        outline_variant_classes
      when :plain
        plain_variant_classes
      else
        solid_variant_classes
      end
    end

    def solid_variant_classes
      color_class = color_classes_for_solid
      [
        "border-transparent",
        "shadow-sm",
        color_class
      ].join(" ")
    end

    def outline_variant_classes
      %w[
        border-zinc-950/10
        text-zinc-950
        hover:bg-zinc-950/2.5
        dark:border-white/15
        dark:text-white
        dark:hover:bg-white/5
      ].join(" ")
    end

    def plain_variant_classes
      %w[
        border-transparent
        text-zinc-950
        hover:bg-zinc-950/5
        dark:text-white
        dark:hover:bg-white/10
      ].join(" ")
    end

    def color_classes_for_solid
      case @color
      when :blue
        "bg-blue-600 hover:bg-blue-700 text-white"
      when :red
        "bg-red-600 hover:bg-red-700 text-white"
      when :green
        "bg-green-600 hover:bg-green-700 text-white"
      when :zinc
        "bg-zinc-600 hover:bg-zinc-700 text-white"
      when :indigo
        "bg-indigo-500 hover:bg-indigo-600 text-white"
      when :amber
        "bg-amber-400 hover:bg-amber-500 text-amber-950"
      when :emerald
        "bg-emerald-600 hover:bg-emerald-700 text-white"
      when :cyan
        "bg-cyan-300 hover:bg-cyan-400 text-cyan-950"
      when :sky
        "bg-sky-500 hover:bg-sky-600 text-white"
      when :violet
        "bg-violet-500 hover:bg-violet-600 text-white"
      when :purple
        "bg-purple-500 hover:bg-purple-600 text-white"
      else
        "bg-blue-600 hover:bg-blue-700 text-white"
      end
    end

    def size_classes
      case @size
      when :sm
        "px-3 py-1.5 text-sm/6"
      when :default
        "px-3.5 py-2.5 text-base/6 sm:px-3 sm:py-1.5 sm:text-sm/6"
      when :lg
        "px-4 py-3 text-base/6"
      else
        "px-3.5 py-2.5 text-base/6 sm:px-3 sm:py-1.5 sm:text-sm/6"
      end
    end
  end
end
