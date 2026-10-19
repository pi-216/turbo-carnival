# frozen_string_literal: true

# @label Base/Tooltip
class TooltipComponentPreview < ViewComponent::Preview
  # @label Default (Top)
  def default
    render_with_template(template: "tooltip_component_preview/default")
  end

  # @label All Positions
  def all_positions
    render_with_template(template: "tooltip_component_preview/all_positions")
  end

  # @label With Buttons
  def with_buttons
    render_with_template(template: "tooltip_component_preview/with_buttons")
  end

  # @label With Icons
  def with_icons
    render_with_template(template: "tooltip_component_preview/with_icons")
  end

  # @label Long Text
  def long_text
    render(Base::TooltipComponent.new(text: "This is a longer tooltip text that provides more detailed information about the element.")) do
      tag.button("Hover for detailed info", class: "rounded-lg bg-blue-600 px-4 py-2 text-white")
    end
  end
end
