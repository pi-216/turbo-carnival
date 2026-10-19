# frozen_string_literal: true

module Catalyst
  # Catalyst Input Component
  #
  # A styled text input with proper focus states and validation support.
  # Based on Catalyst UI Kit: https://catalyst.tailwindui.com/docs/input
  #
  # @example Basic input
  #   <%= render Catalyst::InputComponent.new(name: "email", type: "email") %>
  #
  # @example Input with placeholder
  #   <%= render Catalyst::InputComponent.new(
  #     name: "username",
  #     placeholder: "Enter username"
  #   ) %>
  #
  # @example Input with validation error
  #   <%= render Catalyst::InputComponent.new(
  #     name: "email",
  #     invalid: true
  #   ) %>
  class InputComponent < ApplicationComponent
    def initialize(
      name:,
      type: "text",
      value: nil,
      placeholder: nil,
      required: false,
      disabled: false,
      invalid: false,
      **attributes
    )
      @name = name
      @type = type
      @value = value
      @placeholder = placeholder
      @required = required
      @disabled = disabled
      @invalid = invalid
      @attributes = attributes
    end

    def call
      tag.input(**input_attributes)
    end

    private

    def input_attributes
      {
        type: @type,
        name: @name,
        id: @attributes[:id] || @name,
        value: @value,
        placeholder: @placeholder,
        required: @required,
        disabled: @disabled,
        "aria-invalid": @invalid,
        class: classes
      }.merge(@attributes.except(:class, :id))
    end

    def classes
      [
        base_classes,
        state_classes,
        @attributes[:class]
      ].compact.join(" ")
    end

    def base_classes
      %w[
        block
        w-full
        rounded-lg
        border-0
        bg-white
        dark:bg-white/5
        px-3
        py-2
        text-base/6
        sm:text-sm/6
        text-zinc-950
        dark:text-white
        ring-1
        ring-inset
        placeholder:text-zinc-500
        dark:placeholder:text-zinc-400
        focus:ring-2
        focus:ring-inset
      ].join(" ")
    end

    def state_classes
      if @invalid
        invalid_classes
      elsif @disabled
        disabled_classes
      else
        normal_classes
      end
    end

    def normal_classes
      %w[
        ring-zinc-950/10
        dark:ring-white/10
        focus:ring-blue-500
      ].join(" ")
    end

    def invalid_classes
      %w[
        ring-red-500
        focus:ring-red-500
      ].join(" ")
    end

    def disabled_classes
      %w[
        ring-zinc-950/10
        dark:ring-white/10
        opacity-50
        cursor-not-allowed
      ].join(" ")
    end
  end
end
