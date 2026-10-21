# ViewComponent Guidelines for Turbo Carnival

**Based on:** [ViewComponent Best Practices](https://viewcomponent.org/guide/best_practices.html)

## Our Component Architecture

Following ViewComponent best practices, we organize components into two types:

### 1. General-Purpose Components (Base::)

Located in `app/components/base/` - these implement common UI patterns:

- **Base::ButtonComponent** - Buttons with variants (primary, secondary, outline, ghost, danger)
- **Base::CardComponent** - Cards with slots (header, body, footer)
- **Base::BadgeComponent** - Status indicators, tags, counts (planned)
- **Base::AlertComponent** - Notifications, warnings, errors (planned)
- **Base::InputComponent** - Form inputs (planned)

These are our "design system primitives" - reusable across the entire application.

### 2. Application-Specific Components

Located in `app/components/` - these translate domain objects into UI:

- **VotingCardComponent** - Renders an ImageCandidate for voting
- **ComparisonViewComponent** - Orchestrates A vs B voting interface
- **ImageDisplayComponent** - Displays candidate images

These compose Base components with domain logic.

## Key Decisions We're Following

### ✅ Using -Component Suffix
All components use the `-Component` suffix for clarity:
- `Base::ButtonComponent` (not `Base::Button`)
- `Base::CardComponent` (not `Base::Card`)

### ✅ Avoiding Inheritance
We use **composition over inheritance**:
```ruby
# Good - VotingCardComponent uses Base::CardComponent
<%= render Base::CardComponent.new do |c| %>
  <% c.with_body do %>
    <!-- voting logic -->
  <% end %>
<% end %>

# Bad - Don't inherit from Base::CardComponent
class VotingCardComponent < Base::CardComponent
```

### ✅ Using Slots Over Arguments
We use slots for markup instead of arguments:
```ruby
# Good
<%= render Base::CardComponent.new do |c| %>
  <% c.with_header do %>
    <h3>Title</h3>
  <% end %>
<% end %>

# Bad
<%= render Base::CardComponent.new(header: "<h3>Title</h3>".html_safe) %>
```

### ✅ Testing Against Rendered Content
Our Lookbook previews serve as visual tests. When writing specs:
```ruby
# Good
render_inline(Base::ButtonComponent.new(variant: :primary)) { "Click me" }
assert_text("Click me")
assert_selector("button.bg-\\[--color-primary\\]")

# Bad
assert_equal(Base::ButtonComponent.new.button_classes, "...")
```

### ✅ Private Methods in Components
Helper methods used only in templates are private:
```ruby
class Base::CardComponent < ApplicationComponent
  private

  def card_classes
    # Used in template, but private
  end
end
```

### ✅ Avoiding Global State
Components receive data explicitly, not from `params` or globals:
```ruby
# Good
<%= render VotingCardComponent.new(candidate: @candidate, run: @run) %>

# Bad - don't access params[:run_id] inside component
```

### ✅ No Inline Ruby in Templates
Keep logic in component class, not in ERB:
```ruby
# Good - in component class
def status_color
  active? ? "green" : "gray"
end

# Template
<span class="text-<%= status_color %>-600">

# Bad - in template
<% status_color = @active ? "green" : "gray" %>
```

## Migration Strategy

Following "extract, not invent" principle:

1. **Single use** - Build application-specific component
2. **Multiple uses** - Adapt for general use
3. **Proven pattern** - Extract to Base:: namespace

We're currently at step 3 with Button and Card components.

## Lookbook for Development

We use Lookbook (`/lookbook`) instead of traditional unit tests during development:
- Visual verification of all states
- Interactive testing of variants
- Documentation for developers
- Faster feedback loop than writing specs first

Specs come later for critical components or complex logic.

## Design Tokens Integration

Our Base components use CSS variables from `app/assets/tailwind/design-tokens.css`:

```ruby
# Good - semantic tokens
"bg-[--color-primary]"
"rounded-[--radius-md]"
"shadow-[--shadow-lg]"

# Bad - hardcoded values
"bg-blue-600"
"rounded-lg"
"shadow-lg"
```

This keeps styling consistent and makes theme changes easy.

## What We're Avoiding

### ❌ Replacing Entire Routes with ViewComponents
We're not converting `/runs/index` into a single `RunsIndexComponent`. ViewComponents are for reusable UI patterns, not entire pages.

### ❌ One-Off Components Without Reuse
Every component should serve at least 2-3 use cases, or have clear potential for future reuse.

### ❌ HTML-Generating Helpers
We're migrating away from inline button helpers:
```ruby
# Old (being migrated away)
<%= link_to "Click", path, class: "px-4 py-2 bg-blue-600..." %>

# New
<%= render Base::ButtonComponent.new(href: path) do %>
  Click
<% end %>
```

## References

- **Lookbook:** http://localhost:3003/lookbook
- **ViewComponent Docs:** https://viewcomponent.org/
- **Design Tokens:** `app/assets/tailwind/design-tokens.css`
- **Component Previews:** `spec/components/previews/base/`
