# frozen_string_literal: true

# @label Select
class SelectComponentPreview < ViewComponent::Preview
    # Basic select
    # ---------------
    # Simple select without label
    def default
      render Base::SelectComponent.new(
        name: "country",
        options: [ [ "United States", "us" ], [ "Canada", "ca" ], [ "Mexico", "mx" ], [ "United Kingdom", "uk" ] ]
      )
    end

    # With label and prompt
    # ---------------
    # Select with label and prompt text
    def with_label
      render Base::SelectComponent.new(
        name: "user[country]",
        label: "Country",
        prompt: "Select a country...",
        options: [ [ "United States", "us" ], [ "Canada", "ca" ], [ "Mexico", "mx" ], [ "United Kingdom", "uk" ] ]
      )
    end

    # Required field
    # ---------------
    # Select marked as required with asterisk
    def required
      render Base::SelectComponent.new(
        name: "run[pipeline_id]",
        label: "Pipeline",
        prompt: "Choose a pipeline...",
        options: [ [ "Image Generation", "1" ], [ "Text Processing", "2" ], [ "Video Creation", "3" ] ],
        required: true
      )
    end

    # With selected value
    # ---------------
    # Select with pre-selected value
    def with_selected
      render Base::SelectComponent.new(
        name: "user[timezone]",
        label: "Timezone",
        options: [
          [ "Pacific Time (PT)", "America/Los_Angeles" ],
          [ "Mountain Time (MT)", "America/Denver" ],
          [ "Central Time (CT)", "America/Chicago" ],
          [ "Eastern Time (ET)", "America/New_York" ]
        ],
        selected: "America/Chicago"
      )
    end

    # With error
    # ---------------
    # Select with validation error message
    def with_error
      render Base::SelectComponent.new(
        name: "persona[pillar_id]",
        label: "Content Pillar",
        prompt: "Select a pillar...",
        options: [ [ "Fitness", "1" ], [ "Nutrition", "2" ], [ "Mental Health", "3" ] ],
        error: "Pillar can't be blank"
      )
    end

    # With hint
    # ---------------
    # Select with helpful hint text
    def with_hint
      render Base::SelectComponent.new(
        name: "post[status]",
        label: "Post Status",
        options: [ [ "Draft", "draft" ], [ "Scheduled", "scheduled" ], [ "Published", "published" ] ],
        hint: "Published posts are immediately visible to your audience"
      )
    end

    # Disabled
    # ---------------
    # Disabled select field
    def disabled
      render Base::SelectComponent.new(
        name: "user[plan]",
        label: "Subscription Plan",
        options: [ [ "Free", "free" ], [ "Pro", "pro" ], [ "Enterprise", "enterprise" ] ],
        selected: "pro",
        disabled: true
      )
    end

    # Multiple selection
    # ---------------
    # Select allowing multiple choices
    def multiple
      render Base::SelectComponent.new(
        name: "user[interests][]",
        label: "Interests",
        options: [
          [ "Technology", "tech" ],
          [ "Design", "design" ],
          [ "Marketing", "marketing" ],
          [ "Sales", "sales" ],
          [ "Support", "support" ]
        ],
        selected: [ "tech", "design" ],
        multiple: true,
        hint: "Hold Cmd/Ctrl to select multiple"
      )
    end

    # All states
    # ---------------
    # Shows all select states
    def all_states
      render_with_template(locals: {})
  end
end
