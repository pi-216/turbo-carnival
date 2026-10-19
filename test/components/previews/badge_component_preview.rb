# frozen_string_literal: true

# @label Badge
class BadgeComponentPreview < ViewComponent::Preview
    # Default badge
    # ---------------
    # Basic badge with default styling
    def default
      render Base::BadgeComponent.new do
        "Badge"
      end
    end

    # Primary badge
    # ---------------
    # Primary/brand colored badge
    def primary
      render Base::BadgeComponent.new(variant: :primary) do
        "Primary"
      end
    end

    # Success badge
    # ---------------
    # Success/positive badge
    def success
      render Base::BadgeComponent.new(variant: :success) do
        "Success"
      end
    end

    # Warning badge
    # ---------------
    # Warning badge
    def warning
      render Base::BadgeComponent.new(variant: :warning) do
        "Warning"
      end
    end

    # Danger badge
    # ---------------
    # Danger/error badge
    def danger
      render Base::BadgeComponent.new(variant: :danger) do
        "Danger"
      end
    end

    # Info badge
    # ---------------
    # Informational badge
    def info
      render Base::BadgeComponent.new(variant: :info) do
        "Info"
      end
    end

    # Outline badge
    # ---------------
    # Outline/border-only badge
    def outline
      render Base::BadgeComponent.new(variant: :outline) do
        "Outline"
      end
    end

    # Small size
    # ---------------
    # Small badge
    def small
      render Base::BadgeComponent.new(size: :sm, variant: :primary) do
        "Small"
      end
    end

    # Large size
    # ---------------
    # Large badge
    def large
      render Base::BadgeComponent.new(size: :lg, variant: :primary) do
        "Large"
      end
    end

    # All variants
    # ---------------
    # Shows all badge variants
    def all_variants
      render_with_template(locals: {})
    end

    # All sizes
    # ---------------
    # Shows all badge sizes
    def all_sizes
      render_with_template(locals: {})
    end

    # Status examples
    # ---------------
    # Real-world status examples
    def status_examples
      render_with_template(locals: {})
  end
end
