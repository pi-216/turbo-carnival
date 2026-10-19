# frozen_string_literal: true

module Catalyst
  # Catalyst Sidebar Item Component
  #
  # A navigation item within the sidebar.
  #
  # @example Basic link
  #   <%= render Catalyst::SidebarItemComponent.new(href: "/dashboard") do %>
  #     Dashboard
  #   <% end %>
  #
  # @example Current/active item
  #   <%= render Catalyst::SidebarItemComponent.new(href: "/settings", current: true) do %>
  #     Settings
  #   <% end %>
  #
  # @example With icon (using Heroicons or similar)
  #   <%= render Catalyst::SidebarItemComponent.new(href: "/home") do %>
  #     <svg data-slot="icon" class="size-5" fill="currentColor" viewBox="0 0 20 20">
  #       <!-- icon path -->
  #     </svg>
  #     Home
  #   <% end %>
  class SidebarItemComponent < ApplicationComponent
    def initialize(href: nil, current: false, **attributes)
      @href = href
      @current = current
      @attributes = attributes
    end

    def call
      if @href
        link_to @href, class: link_classes, data: { turbo_frame: @attributes[:data]&.dig(:turbo_frame) } do
          content
        end
      else
        tag.button content, class: link_classes, **@attributes
      end
    end

    private

    def link_classes
      [
        base_classes,
        state_classes,
        @attributes[:class]
      ].compact.join(" ")
    end

    def base_classes
      %w[
        relative
        flex
        w-full
        items-center
        gap-3
        rounded-lg
        px-2
        py-2.5
        text-left
        text-base/6
        font-medium
        text-white
        sm:py-2
        sm:text-sm/5
      ].join(" ")
    end

    def state_classes
      if @current
        current_classes
      else
        normal_classes
      end
    end

    def normal_classes
      %w[
        hover:bg-white/5
      ].join(" ")
    end

    def current_classes
      %w[
        bg-white/10
        font-semibold
      ].join(" ")
    end
  end
end
