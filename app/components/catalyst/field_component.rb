# frozen_string_literal: true

module Catalyst
  # Catalyst Field Component
  #
  # A form field wrapper with label, description, and error message support.
  # Based on Catalyst UI Kit fieldset patterns.
  #
  # @example Basic field with label
  #   <%= render Catalyst::FieldComponent.new do |field| %>
  #     <% field.with_label { "Email address" } %>
  #     <%= render Catalyst::InputComponent.new(name: "email", type: "email") %>
  #   <% end %>
  #
  # @example Field with description
  #   <%= render Catalyst::FieldComponent.new do |field| %>
  #     <% field.with_label { "Password" } %>
  #     <% field.with_description { "Must be at least 8 characters" } %>
  #     <%= render Catalyst::InputComponent.new(name: "password", type: "password") %>
  #   <% end %>
  #
  # @example Field with error
  #   <%= render Catalyst::FieldComponent.new do |field| %>
  #     <% field.with_label { "Email" } %>
  #     <%= render Catalyst::InputComponent.new(name: "email", invalid: true) %>
  #     <% field.with_error { "Email is required" } %>
  #   <% end %>
  class FieldComponent < ApplicationComponent
    renders_one :label
    renders_one :description
    renders_one :error

    def initialize(**attributes)
      @attributes = attributes
    end

    private

    def container_classes
      [
        "space-y-3",
        @attributes[:class]
      ].compact.join(" ")
    end

    def label_classes
      %w[
        block
        text-sm/6
        font-medium
        text-zinc-950
        dark:text-white
      ].join(" ")
    end

    def description_classes
      %w[
        text-sm/6
        text-zinc-500
        dark:text-zinc-400
      ].join(" ")
    end

    def error_classes
      %w[
        text-sm/6
        text-red-600
        dark:text-red-400
      ].join(" ")
    end
  end
end
