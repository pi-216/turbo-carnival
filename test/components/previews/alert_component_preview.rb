# frozen_string_literal: true

# @label Alert
class AlertComponentPreview < ViewComponent::Preview
    # Success alert
    # ---------------
    # Success message alert
    def success
      render Base::AlertComponent.new(variant: :success) do
        "Your changes have been saved successfully!"
      end
    end

    # Info alert
    # ---------------
    # Informational message alert
    def info
      render Base::AlertComponent.new(variant: :info) do
        "This feature is currently in beta. Please report any issues."
      end
    end

    # Warning alert
    # ---------------
    # Warning message alert
    def warning
      render Base::AlertComponent.new(variant: :warning) do
        "Your session will expire in 5 minutes. Please save your work."
      end
    end

    # Danger alert
    # ---------------
    # Error/danger message alert
    def danger
      render Base::AlertComponent.new(variant: :danger) do
        "There was a problem processing your request. Please try again."
      end
    end

    # With title
    # ---------------
    # Alert with a title
    def with_title
      render Base::AlertComponent.new(variant: :warning, title: "Payment Required") do
        "Your trial period has ended. Please update your payment information to continue using the service."
      end
    end

    # Dismissible
    # ---------------
    # Alert that can be dismissed
    def dismissible
      render Base::AlertComponent.new(variant: :info, dismissible: true) do
        "New features have been added! Click here to learn more."
      end
    end

    # All variants
    # ---------------
    # Shows all alert variants
    def all_variants
      render_with_template(locals: {})
  end
end
