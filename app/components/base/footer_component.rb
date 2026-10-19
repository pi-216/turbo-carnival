# frozen_string_literal: true

module Base
  class FooterComponent < ViewComponent::Base
    renders_many :sections, "SectionComponent"
    renders_one :bottom

    def initialize(variant: :default)
      @variant = variant
    end

    private

    def container_classes
      "bg-gray-900 border-t border-gray-800 mt-auto"
    end

    class SectionComponent < ViewComponent::Base
      renders_one :title
      renders_many :links, "LinkComponent"

      def call
        "" # This component is used for data structuring only, rendered by parent
      end

      class LinkComponent < ViewComponent::Base
        def initialize(href:)
          @href = href
        end

        def call
          link_to @href, class: "text-sm text-gray-400 hover:text-white transition-colors" do
            content
          end
        end
      end
    end
  end
end
