# frozen_string_literal: true

# @label Input
class InputComponentPreview < ViewComponent::Preview
    # Basic text input
    # ---------------
    # Simple text input without label
    def default
      render Base::InputComponent.new(
        name: "example",
        placeholder: "Enter text..."
      )
    end

    # With label
    # ---------------
    # Input with label text
    def with_label
      render Base::InputComponent.new(
        name: "user[name]",
        label: "Full Name",
        placeholder: "John Doe"
      )
    end

    # Required field
    # ---------------
    # Input marked as required with asterisk
    def required
      render Base::InputComponent.new(
        name: "user[email]",
        type: :email,
        label: "Email Address",
        placeholder: "you@example.com",
        required: true
      )
    end

    # With error
    # ---------------
    # Input with validation error message
    def with_error
      render Base::InputComponent.new(
        name: "user[email]",
        type: :email,
        label: "Email Address",
        value: "invalid-email",
        error: "Email must be a valid email address"
      )
    end

    # With hint
    # ---------------
    # Input with helpful hint text
    def with_hint
      render Base::InputComponent.new(
        name: "user[username]",
        label: "Username",
        placeholder: "johndoe",
        hint: "Choose a unique username (3-20 characters)"
      )
    end

    # Disabled
    # ---------------
    # Disabled input field
    def disabled
      render Base::InputComponent.new(
        name: "user[id]",
        label: "User ID",
        value: "12345",
        disabled: true
      )
    end

    # Different types
    # ---------------
    # Various input types
    # @param type select { choices: [text, email, password, number, tel, url, search] }
    def types(type: :text)
      render Base::InputComponent.new(
        name: "example",
        type: type.to_sym,
        label: "#{type.to_s.titleize} Input",
        placeholder: "Enter #{type}..."
      )
    end

    # All states
    # ---------------
    # Shows all input states side by side
    def all_states
      render_with_template(locals: {})
  end
end
