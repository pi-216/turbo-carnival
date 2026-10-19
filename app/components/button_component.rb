# frozen_string_literal: true

# A reusable button component with multiple style variants.
#
# @example Primary button
#   <%= render ButtonComponent.new(text: "Submit", variant: :primary) %>
#
# @example Danger button with custom classes
#   <%= render ButtonComponent.new(text: "Delete", variant: :danger, classes: "mt-4") %>
class ButtonComponent < ApplicationComponent
  # @param text [String] the button label text
  # @param variant [Symbol] the style variant (:primary, :secondary, :danger)
  # @param classes [String] additional CSS classes to append
  # @param type [String] the button type attribute (button, submit, reset)
  def initialize(text:, variant: :primary, classes: "", type: "button")
    @text = text
    @variant = variant
    @classes = classes
    @type = type
  end

  private

  def button_classes
    base_classes = "px-4 py-2 rounded-lg transition-colors font-medium"
    variant_classes = case @variant
    when :primary
      "bg-blue-600 hover:bg-blue-700 text-white"
    when :secondary
      "bg-gray-600 hover:bg-gray-700 text-white"
    when :danger
      "bg-red-600 hover:bg-red-700 text-white"
    else
      "bg-gray-600 hover:bg-gray-700 text-white"
    end

    [ base_classes, variant_classes, @classes ].join(" ")
  end
end
