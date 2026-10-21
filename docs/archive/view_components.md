# ViewComponent Guide

> **Status:** UNREVIEWED — predates the 2026-10 rebuild

## Overview

This project uses [ViewComponent](https://viewcomponent.org/) to build reusable, testable UI components. ViewComponents are Ruby objects that encapsulate view logic and templates.

## Benefits

- **Testable**: Components are unit-testable in isolation
- **Reusable**: Designed for use across this project and future projects
- **Maintainable**: Clear APIs with keyword arguments
- **Performant**: ~10x faster than partials
- **Type-safe**: Explicit contracts via `initialize` parameters

## Component Structure

```
app/components/
├── application_component.rb          # Base class
├── button_component.rb               # Component logic
├── button_component.html.erb         # Template
└── ...

spec/components/
├── button_component_spec.rb          # Unit tests
└── ...

test/components/previews/
├── button_component_preview.rb       # Visual previews
└── ...
```

## Creating a Component

### 1. Generate Component Files

Create a Ruby class in `app/components/`:

```ruby
# app/components/alert_component.rb
class AlertComponent < ApplicationComponent
  # @param message [String] the alert message
  # @param type [Symbol] alert type (:info, :warning, :error)
  def initialize(message:, type: :info)
    @message = message
    @type = type
  end

  private

  def css_classes
    base = "px-4 py-3 rounded"
    variant = case @type
    when :info then "bg-blue-100 text-blue-900"
    when :warning then "bg-yellow-100 text-yellow-900"
    when :error then "bg-red-100 text-red-900"
    end
    [base, variant].join(" ")
  end
end
```

### 2. Create Template

Create ERB template in `app/components/`:

```erb
<%# app/components/alert_component.html.erb %>
<div class="<%= css_classes %>">
  <%= @message %>
</div>
```

### 3. Render in Views

```erb
<%# In any view file %>
<%= render AlertComponent.new(message: "Success!", type: :info) %>
```

## Testing Components

### Unit Tests with RSpec

Create spec in `spec/components/`:

```ruby
# spec/components/alert_component_spec.rb
require "rails_helper"

RSpec.describe AlertComponent, type: :component do
  it "renders info alert" do
    result = render_inline(AlertComponent.new(message: "Hello", type: :info))
    expect(result.to_html).to include("Hello")
    expect(result.to_html).to include("bg-blue-100")
  end

  it "renders error alert" do
    result = render_inline(AlertComponent.new(message: "Error", type: :error))
    expect(result.to_html).to include("bg-red-100")
  end
end
```

### Running Tests

```bash
# Test all components
bundle exec rspec spec/components/

# Test specific component
bundle exec rspec spec/components/alert_component_spec.rb
```

## Component Previews

Previews allow visual testing during development.

### Creating a Preview

```ruby
# test/components/previews/alert_component_preview.rb
class AlertComponentPreview < ViewComponent::Preview
  def info
    render AlertComponent.new(message: "Info message", type: :info)
  end

  def error
    render AlertComponent.new(message: "Error occurred", type: :error)
  end
end
```

### Viewing Previews

1. Start Rails server: `bin/rails server`
2. Navigate to: `http://localhost:3000/rails/view_components`
3. Select component to preview

## Using Slots

For components with multiple content areas:

```ruby
class ModalComponent < ApplicationComponent
  renders_one :header
  renders_one :body
  renders_one :footer
end
```

```erb
<%# modal_component.html.erb %>
<div class="modal">
  <% if header? %>
    <div class="modal-header"><%= header %></div>
  <% end %>
  <% if body? %>
    <div class="modal-body"><%= body %></div>
  <% end %>
  <% if footer? %>
    <div class="modal-footer"><%= footer %></div>
  <% end %>
</div>
```

Usage:

```erb
<%= render ModalComponent.new do |modal| %>
  <% modal.with_header { "Title" } %>
  <% modal.with_body { "Content" } %>
  <% modal.with_footer { "Actions" } %>
<% end %>
```

## Available Components

### ButtonComponent

Renders styled buttons with variants.

```erb
<%= render ButtonComponent.new(text: "Submit", variant: :primary) %>
<%= render ButtonComponent.new(text: "Cancel", variant: :secondary) %>
<%= render ButtonComponent.new(text: "Delete", variant: :danger) %>
```

**Parameters:**
- `text:` (String, required) - Button label
- `variant:` (Symbol, default: :primary) - Style variant (`:primary`, `:secondary`, `:danger`)
- `type:` (String, default: "button") - HTML button type
- `classes:` (String, default: "") - Additional CSS classes

### CardComponent

Container with optional header, body, and footer slots.

```erb
<%= render CardComponent.new(classes: "shadow-xl") do |card| %>
  <% card.with_header { "Card Title" } %>
  <% card.with_body { "Content here" } %>
  <% card.with_footer { "Footer actions" } %>
<% end %>
```

**Parameters:**
- `classes:` (String, default: "") - Additional CSS classes

**Slots:**
- `header` - Optional header section
- `body` - Main content area
- `footer` - Optional footer section

### ImageDisplayComponent

Displays image with fallback when missing.

```erb
<%= render ImageDisplayComponent.new(
  image_path: @image.path,
  fallback_text: "No image available",
  classes: "max-w-full"
) %>
```

**Parameters:**
- `image_path:` (String, required) - Path to image
- `fallback_text:` (String, default: "No image") - Text shown when image missing
- `classes:` (String, default: "") - CSS classes for `<img>` tag
- `container_classes:` (String, default: "") - CSS classes for wrapper `<div>`

## Best Practices

### Component Design

1. **Single Responsibility**: Each component should do one thing well
2. **Reusability**: Design for use in multiple contexts
3. **Explicit Parameters**: Use keyword arguments with defaults
4. **Documentation**: Add YARD-style comments for parameters
5. **Composition**: Prefer small components that compose together

### When to Create a Component

✅ **Create a component when:**
- Pattern is used in 2+ places
- Logic needs unit testing
- Preparing for cross-project reuse
- Encapsulation improves clarity

❌ **Don't create a component for:**
- One-off, page-specific UI
- Simple partials with no logic
- Premature abstraction

### Naming Conventions

- Suffix all components with `Component`
- Use descriptive names: `UserAvatarComponent`, not `Avatar`
- Match file and class names: `user_avatar_component.rb` → `UserAvatarComponent`

### CSS and Styling

- Use Tailwind utility classes in templates
- Extract repeated class patterns to private methods
- Accept `classes:` parameter for customization
- Apply base classes first, then variant classes, then custom classes

### Testing Strategy

- Test all variants and edge cases
- Test with nil/empty values
- Use `result.to_html.include?()` for assertions
- Keep tests fast and focused

## Extracting to Shared Library

Components are designed for eventual extraction to a shared gem or pack.

### Preparation Checklist

- ✅ Clear, documented API
- ✅ No direct dependencies on app models
- ✅ Comprehensive test coverage
- ✅ Working component previews
- ✅ Generic, reusable design

### Future Extraction

When ready to share across projects:

1. Create new gem: `bundle gem ui_components`
2. Move components to gem's `app/components/`
3. Move tests to gem's `spec/`
4. Publish gem or add as path dependency
5. Replace local components with gem

## Troubleshooting

### Component not rendering

- Check component inherits from `ApplicationComponent`
- Verify template file exists with matching name
- Ensure `render` helper is used correctly

### Preview not showing

- Check file is in `test/components/previews/`
- Class must inherit from `ViewComponent::Preview`
- Server may need restart

### Tests failing

- Ensure `type: :component` is set
- Use `render_inline()` not `render()`
- Check `result.to_html` for assertions
- Verify ViewComponent test helpers are loaded in `rails_helper.rb`

## Resources

- [ViewComponent Documentation](https://viewcomponent.org/)
- [ViewComponent GitHub](https://github.com/viewcomponent/view_component)
- [ViewComponent Best Practices](https://viewcomponent.org/guide/best-practices.html)
