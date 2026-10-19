# frozen_string_literal: true

module Layout
  class ContainerComponent < ViewComponent::Base
    def initialize(max_width: "7xl")
      @max_width = max_width
    end

    private

    def container_classes
      [
        "mx-auto",
        "px-4 sm:px-6 lg:px-8",
        max_width_class
      ].join(" ")
    end

    def max_width_class
      case @max_width
      when "sm" then "max-w-sm"
      when "md" then "max-w-md"
      when "lg" then "max-w-lg"
      when "xl" then "max-w-xl"
      when "2xl" then "max-w-2xl"
      when "3xl" then "max-w-3xl"
      when "4xl" then "max-w-4xl"
      when "5xl" then "max-w-5xl"
      when "6xl" then "max-w-6xl"
      when "7xl" then "max-w-7xl"
      when "full" then "max-w-full"
      else "max-w-7xl"
      end
    end
  end
end
