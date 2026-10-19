# frozen_string_literal: true

module Catalyst
  # Catalyst Sidebar Layout Component
  #
  # A responsive application layout with a sidebar for navigation.
  # Based on Catalyst UI Kit: https://catalyst.tailwindui.com/docs/sidebar-layout
  #
  # @example Basic sidebar layout
  #   <%= render Catalyst::SidebarLayoutComponent.new do |layout| %>
  #     <% layout.with_sidebar do %>
  #       <%= render Catalyst::SidebarComponent.new do |sidebar| %>
  #         <!-- Sidebar content -->
  #       <% end %>
  #     <% end %>
  #     <!-- Page content -->
  #   <% end %>
  class SidebarLayoutComponent < ApplicationComponent
    renders_one :sidebar
    renders_one :navbar

    def initialize(**attributes)
      @attributes = attributes
    end

    private

    def layout_classes
      %w[
        relative
        isolate
        flex
        min-h-svh
        w-full
        bg-white
        max-lg:flex-col
        lg:bg-zinc-100
        dark:bg-zinc-900
        dark:lg:bg-zinc-950
      ].join(" ")
    end

    def sidebar_desktop_classes
      %w[
        fixed
        inset-y-0
        left-0
        w-64
        max-lg:hidden
      ].join(" ")
    end

    def main_classes
      %w[
        flex
        flex-1
        flex-col
        pb-2
        lg:min-w-0
        lg:pt-2
        lg:pr-2
        lg:pl-64
      ].join(" ")
    end

    def content_classes
      %w[
        grow
        p-6
        lg:rounded-lg
        lg:bg-white
        lg:p-10
        lg:shadow-sm
        lg:ring-1
        lg:ring-zinc-950/5
        dark:lg:bg-zinc-900
        dark:lg:ring-white/10
      ].join(" ")
    end

    def max_width_classes
      "mx-auto max-w-6xl"
    end
  end
end
