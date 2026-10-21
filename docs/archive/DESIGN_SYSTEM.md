# Design System

## Overview

This application uses a comprehensive design system built on ViewComponent and Tailwind CSS v4. All UI components follow consistent patterns for styling, accessibility, and composition.

## Quick Start

### View All Components

Visit `/lookbook` in development to browse all components interactively:

```bash
bin/dev
# Navigate to http://localhost:3003/lookbook
```

### Using Components

Components are organized under the `Base::` namespace:

```erb
<%# Buttons %>
<%= render Base::ButtonComponent.new(variant: :primary) do %>
  Save Changes
<% end %>

<%# Forms %>
<%= render Base::InputComponent.new(
  name: "user[email]",
  label: "Email",
  type: :email,
  required: true
) %>

<%# Cards %>
<%= render Base::CardComponent.new(variant: :elevated) do %>
  <p>Card content goes here</p>
<% end %>

<%# Modals %>
<%= render Base::ModalComponent.new(id: "confirm-modal", title: "Confirm Action", size: :md) do %>
  <p>Are you sure?</p>
  <% content_for :footer do %>
    <%= render Base::ButtonComponent.new(variant: :danger) { "Delete" } %>
  <% end %>
<% end %>
```

## Available Components

### Interactive Elements

- **Base::ButtonComponent** - 6 variants (primary, secondary, ghost, danger, warning, success)
- **Base::TooltipComponent** - 4 positions (top, bottom, left, right)
- **Base::TabsComponent** - Tab navigation with active states

### Form Components

- **Base::InputComponent** - Text, email, password, number inputs
- **Base::SelectComponent** - Dropdown selects with validation
- **Base::TextareaComponent** - Multi-line text input
- **Base::CheckboxComponent** - Checkboxes with labels

### Layout & Display

- **Base::CardComponent** - 3 variants (default, elevated, interactive)
- **Base::ModalComponent** - 5 sizes (sm, md, lg, xl, full)
- **Base::AlertComponent** - 4 types (info, success, warning, error)
- **Base::BadgeComponent** - 5 variants + 3 sizes
- **Base::LoadingComponent** - 3 variants (spinner, skeleton, dots)
- **Base::NavbarComponent** - Top navigation with logo, items, actions, mobile menu
- **Base::SidebarComponent** - Collapsible sidebar with sections and items
- **Base::LayoutComponent** - Full page layout wrapper (navbar + sidebar + main + footer)
- **Base::FooterComponent** - Footer with sections and links

## Design Tokens

Design tokens are defined in `app/assets/stylesheets/design-tokens.css`:

```css
@theme {
  /* Colors */
  --color-primary-*: /* Blue scale */
  --color-surface-*: /* Zinc scale */
  --color-success-*: /* Green scale */
  --color-warning-*: /* Yellow scale */
  --color-error-*: /* Red scale */
  
  /* Typography */
  --font-family-sans: system-ui, sans-serif;
  --font-size-*: /* Scale from xs to 4xl */
  
  /* Spacing, shadows, radii */
  --spacing-*: /* 0 to 96 */
  --shadow-*: /* sm to 2xl */
  --radius-*: /* sm to 2xl */
}
```

## Component Guidelines

### Composition Over Inheritance

Build feature components by composing Base components:

```ruby
# app/components/user_profile_card_component.rb
class UserProfileCardComponent < ViewComponent::Base
  def initialize(user:)
    @user = user
  end
end
```

```erb
<%# app/components/user_profile_card_component.html.erb %>
<%= render Base::CardComponent.new(variant: :elevated) do %>
  <div class="flex items-center gap-4">
    <img src="<%= @user.avatar_url %>" class="h-12 w-12 rounded-full" />
    <div>
      <h3 class="font-semibold"><%= @user.name %></h3>
      <%= render Base::BadgeComponent.new(variant: :success, size: :sm) do %>
        Active
      <% end %>
    </div>
  </div>
<% end %>
```

### Avoid Inline Styles

Use Tailwind utility classes, not inline styles:

```erb
<%# Good %>
<div class="flex items-center gap-4">

<%# Bad %>
<div style="display: flex; align-items: center; gap: 1rem;">
```

### Accessibility First

- All form inputs have labels
- Buttons have clear text or `aria-label`
- Modals have `role="dialog"` and `aria-modal="true"`
- Color is never the only indicator (icons + text for alerts)

## Testing

All Base components have RSpec tests in `spec/components/base/`:

```bash
bundle exec rspec spec/components/base/
```

## Documentation

- **Lookbook**: `/lookbook` - Interactive component browser
- **This file**: High-level overview and usage
- **openspec/changes/add-design-system/**: Detailed proposal and decisions

## Future Enhancements

See `openspec/changes/add-design-system/tasks.md` for:
- Layout components (Navbar, Sidebar, Footer)
- Complete form migration
- Additional accessibility improvements
