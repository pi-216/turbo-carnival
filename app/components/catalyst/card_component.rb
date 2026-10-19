# frozen_string_literal: true

module Catalyst
  # Catalyst Card Component
  #
  # A card container with optional header and footer sections.
  # Based on Catalyst UI Kit design patterns.
  #
  # @example Basic card
  #   <%= render Catalyst::CardComponent.new do %>
  #     <p>Card content here</p>
  #   <% end %>
  #
  # @example Card with header
  #   <%= render Catalyst::CardComponent.new do |card| %>
  #     <% card.with_header do %>
  #       <h2 class="text-lg/7 font-semibold">Card Title</h2>
  #     <% end %>
  #     <p>Card content here</p>
  #   <% end %>
  #
  # @example Card with header and footer
  #   <%= render Catalyst::CardComponent.new do |card| %>
  #     <% card.with_header do %>
  #       <h2>Title</h2>
  #     <% end %>
  #     <p>Content</p>
  #     <% card.with_footer do %>
  #       <%= render Catalyst::ButtonComponent.new do %>Save<% end %>
  #     <% end %>
  #   <% end %>
  class CardComponent < ApplicationComponent
    renders_one :header
    renders_one :footer

    def initialize(**attributes)
      @attributes = attributes
    end

    private

    def card_classes
      [
        "bg-white",
        "dark:bg-zinc-900",
        "rounded-xl",
        "shadow-sm",
        "border",
        "border-zinc-950/10",
        "dark:border-white/10",
        "overflow-hidden",
        @attributes[:class]
      ].compact.join(" ")
    end

    def header_classes
      %w[
        border-b
        border-zinc-950/10
        dark:border-white/10
        px-6
        py-4
      ].join(" ")
    end

    def body_classes
      %w[
        p-6
        sm:p-8
      ].join(" ")
    end

    def footer_classes
      %w[
        border-t
        border-zinc-950/10
        dark:border-white/10
        px-6
        py-4
        bg-zinc-50
        dark:bg-zinc-950/50
      ].join(" ")
    end
  end
end
