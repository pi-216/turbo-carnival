# frozen_string_literal: true

module Base
  class NavbarComponent < ViewComponent::Base
    renders_one :logo
    renders_many :items, "ItemComponent"
    renders_one :actions

    def initialize(fixed: true, mobile_menu: true)
      @fixed = fixed
      @mobile_menu = mobile_menu
    end

    private

    def container_classes
      classes = [ "bg-gray-900", "border-b", "border-gray-800" ]
      classes << "sticky top-0 z-50" if @fixed
      classes.join(" ")
    end

    class ItemComponent < ViewComponent::Base
      def initialize(href:, active: false)
        @href = href
        @active = active
      end

      def call
        link_to @href, class: item_classes do
          content
        end
      end

      private

      def item_classes
        base = "px-4 py-6 text-sm font-medium transition-colors"
        if @active
          "#{base} text-white border-b-2 border-blue-500"
        else
          "#{base} text-gray-400 hover:text-white hover:bg-gray-800"
        end
      end
    end
  end
end
