# frozen_string_literal: true

module Base
  class LayoutComponent < ViewComponent::Base
    renders_one :navbar
    renders_one :sidebar
    renders_one :main
    renders_one :footer

    def initialize(full_width: false)
      @full_width = full_width
    end

    private

    def main_classes
      base = "flex-1 overflow-auto"
      base += " bg-gray-950" unless @full_width
      base
    end

    def content_classes
      return "" if @full_width
      "max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8"
    end
  end
end
