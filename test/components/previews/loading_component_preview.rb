# frozen_string_literal: true

# @label Loading
class LoadingComponentPreview < ViewComponent::Preview
    # Small spinner
    # ---------------
    # Small loading spinner
    def small
      render Base::LoadingComponent.new(size: :sm)
    end

    # Medium spinner
    # ---------------
    # Default medium loading spinner
    def medium
      render Base::LoadingComponent.new(size: :md)
    end

    # Large spinner
    # ---------------
    # Large loading spinner
    def large
      render Base::LoadingComponent.new(size: :lg)
    end

    # With text
    # ---------------
    # Spinner with loading text
    def with_text
      render Base::LoadingComponent.new(
        text: "Loading candidates..."
      )
    end

    # Centered
    # ---------------
    # Centered spinner (fills space)
    def centered
      render Base::LoadingComponent.new(
        size: :lg,
        text: "Processing images...",
        centered: true
      )
    end

    # Inline variant
    # ---------------
    # Inline spinner with text
    def inline
      render Base::LoadingComponent.new(
        size: :sm,
        variant: :inline,
        text: "Saving..."
      )
    end

    # Inline with content
    # ---------------
    # Inline spinner with block content
    def inline_with_content
      render Base::LoadingComponent.new(size: :sm, variant: :inline) do
        "Processing your request..."
      end
    end

    # All sizes
    # ---------------
    # Shows all spinner sizes and variants
    def all_sizes
      render_with_template(locals: {})
  end
end
