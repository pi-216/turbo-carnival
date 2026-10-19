# frozen_string_literal: true

module Catalyst
  # Catalyst Sidebar Component
  #
  # A sidebar navigation component with header, body, and footer sections.
  # Based on Catalyst UI Kit: https://catalyst.tailwindui.com/docs/sidebar
  #
  # @example Sidebar with sections
  #   <%= render Catalyst::SidebarComponent.new do |sidebar| %>
  #     <% sidebar.with_header do %>
  #       <h1 class="text-lg font-semibold">App Name</h1>
  #     <% end %>
  #     <% sidebar.with_body do %>
  #       <%= render Catalyst::SidebarSectionComponent.new do %>
  #         <%= render Catalyst::SidebarItemComponent.new(href: "/", current: true) do %>
  #           Dashboard
  #         <% end %>
  #       <% end %>
  #     <% end %>
  #   <% end %>
  class SidebarComponent < ApplicationComponent
    renders_one :header
    renders_one :body
    renders_one :footer

    def initialize(**attributes)
      @attributes = attributes
    end

    private

    def sidebar_classes
      %w[
        flex
        h-full
        min-h-0
        flex-col
        bg-zinc-900
        dark:bg-zinc-950
      ].join(" ")
    end

    def header_classes
      %w[
        flex
        flex-col
        border-b
        border-white/10
        p-4
      ].join(" ")
    end

    def body_classes
      %w[
        flex
        flex-1
        flex-col
        overflow-y-auto
        p-4
      ].join(" ")
    end

    def footer_classes
      %w[
        flex
        flex-col
        border-t
        border-white/10
        p-4
      ].join(" ")
    end
  end
end
