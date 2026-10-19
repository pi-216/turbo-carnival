# frozen_string_literal: true

# @label Button
class ButtonComponentPreview < ViewComponent::Preview
  # @label Default (Primary)
  def default
    render Base::ButtonComponent.new do
      "Click me"
    end
  end

  # @label All Variants
  def all_variants
    render_with_template
  end

  # @label With Icons
  def with_icons
    render_with_template
  end

  # @label Disabled States
  def disabled
    render_with_template
  end

  # @label As Links
  def as_links
    render_with_template
  end

  # @label Different Sizes
  def sizes
    render_with_template
  end
end
