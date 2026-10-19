# frozen_string_literal: true

# @label Textarea
class TextareaComponentPreview < ViewComponent::Preview
    # Basic textarea
    # ---------------
    # Simple textarea without label
    def default
      render Base::TextareaComponent.new(
        name: "example",
        placeholder: "Enter text..."
      )
    end

    # With label
    # ---------------
    # Textarea with label text
    def with_label
      render Base::TextareaComponent.new(
        name: "post[content]",
        label: "Post Content",
        placeholder: "Write your post..."
      )
    end

    # Required field
    # ---------------
    # Textarea marked as required with asterisk
    def required
      render Base::TextareaComponent.new(
        name: "comment[body]",
        label: "Comment",
        placeholder: "Add a comment...",
        required: true,
        rows: 3
      )
    end

    # With error
    # ---------------
    # Textarea with validation error message
    def with_error
      render Base::TextareaComponent.new(
        name: "post[content]",
        label: "Post Content",
        value: "Too short",
        error: "Content must be at least 50 characters",
        rows: 4
      )
    end

    # With hint
    # ---------------
    # Textarea with helpful hint text
    def with_hint
      render Base::TextareaComponent.new(
        name: "bio",
        label: "Biography",
        placeholder: "Tell us about yourself...",
        hint: "Maximum 500 characters",
        rows: 5
      )
    end

    # Disabled
    # ---------------
    # Disabled textarea field
    def disabled
      render Base::TextareaComponent.new(
        name: "notes",
        label: "Notes",
        value: "This content cannot be edited",
        disabled: true,
        rows: 3
      )
    end

    # Different sizes
    # ---------------
    # Various textarea row counts
    # @param rows select { choices: [3, 5, 8, 12] }
    def sizes(rows: 5)
      render Base::TextareaComponent.new(
        name: "example",
        label: "#{rows} Rows",
        placeholder: "Enter text...",
        rows: rows
      )
    end

    # All states
    # ---------------
    # Shows all textarea states
    def all_states
      render_with_template(locals: {})
  end
end
