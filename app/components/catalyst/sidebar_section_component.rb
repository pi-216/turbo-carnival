# frozen_string_literal: true

module Catalyst
  # Catalyst Sidebar Section Component
  #
  # A grouped section within the sidebar.
  #
  # @example Section with heading
  #   <%= render Catalyst::SidebarSectionComponent.new(heading: "Navigation") do %>
  #     <%= render Catalyst::SidebarItemComponent.new(href: "/home") do %>Home<% end %>
  #   <% end %>
  class SidebarSectionComponent < ApplicationComponent
    def initialize(heading: nil, **attributes)
      @heading = heading
      @attributes = attributes
    end

    private

    def section_classes
      "flex flex-col gap-0.5 mt-8 first:mt-0"
    end

    def heading_classes
      %w[
        mb-1
        px-2
        text-xs/6
        font-medium
        text-zinc-400
      ].join(" ")
    end
  end
end
