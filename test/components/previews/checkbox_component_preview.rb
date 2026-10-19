# frozen_string_literal: true

# @label Checkbox
class CheckboxComponentPreview < ViewComponent::Preview
    # Basic checkbox
    # ---------------
    # Simple unchecked checkbox
    def default
      render Base::CheckboxComponent.new(
        name: "example",
        label: "Enable notifications"
      )
    end

    # Checked
    # ---------------
    # Checkbox that is checked
    def checked
      render Base::CheckboxComponent.new(
        name: "settings[enabled]",
        label: "Feature enabled",
        checked: true
      )
    end

    # With hint
    # ---------------
    # Checkbox with helpful hint text
    def with_hint
      render Base::CheckboxComponent.new(
        name: "persona[public]",
        label: "Make this persona public",
        hint: "Public personas can be discovered by other users in the community"
      )
    end

    # Disabled unchecked
    # ---------------
    # Disabled checkbox (unchecked)
    def disabled_unchecked
      render Base::CheckboxComponent.new(
        name: "locked_feature",
        label: "Premium feature (upgrade required)",
        disabled: true
      )
    end

    # Disabled checked
    # ---------------
    # Disabled checkbox (checked)
    def disabled_checked
      render Base::CheckboxComponent.new(
        name: "required_setting",
        label: "Required security setting",
        checked: true,
        disabled: true,
        hint: "This setting cannot be changed for security reasons"
      )
    end

    # Long label
    # ---------------
    # Checkbox with long wrapping label
    def long_label
      render Base::CheckboxComponent.new(
        name: "terms",
        label: "I agree to the Terms of Service and Privacy Policy, and I understand that my data will be processed according to these documents",
        hint: "You must accept the terms to continue"
      )
    end

    # Multiple checkboxes
    # ---------------
    # Group of related checkboxes
    def all_states
      render_with_template(locals: {})
  end
end
