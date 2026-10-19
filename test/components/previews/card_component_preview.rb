# frozen_string_literal: true

# @label Card
class CardComponentPreview < ViewComponent::Preview
  # @label Default
  def default
    render Base::CardComponent.new do |c|
      c.with_body do
        "Basic card with just body content"
      end
    end
  end

  # @label All Variants
  def all_variants
    render_with_template
  end

  # @label With Header and Footer
  def with_header_footer
    render_with_template
  end

  # @label Interactive Cards
  def interactive
    render_with_template
  end

  # @label Dashboard Example
  def dashboard_example
    render_with_template
  end
end
