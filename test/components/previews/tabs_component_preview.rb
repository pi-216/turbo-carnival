# frozen_string_literal: true

# @label Base/Tabs
class TabsComponentPreview < ViewComponent::Preview
  # @label Default
  def default
    render(Base::TabsComponent.new) do |component|
      component.with_tab(id: "tab1", label: "Overview", active: true)
      component.with_tab(id: "tab2", label: "Details")
      component.with_tab(id: "tab3", label: "Settings")
    end
  end

  # @label With Icons
  def with_icons
    render(Base::TabsComponent.new) do |component|
      component.with_tab(id: "tab1", label: "📊 Dashboard", active: true)
      component.with_tab(id: "tab2", label: "👥 Users")
      component.with_tab(id: "tab3", label: "⚙️ Settings")
      component.with_tab(id: "tab4", label: "🔔 Notifications")
    end
  end

  # @label Many Tabs
  def many_tabs
    render(Base::TabsComponent.new) do |component|
      [ "Home", "Products", "Services", "About", "Contact", "Blog", "FAQ", "Support" ].each_with_index do |label, index|
        component.with_tab(id: "tab#{index}", label: label, active: index.zero?)
      end
    end
  end
end
