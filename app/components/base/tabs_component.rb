# frozen_string_literal: true

class Base::TabsComponent < ViewComponent::Base
  renders_many :tabs, "TabComponent"

  attr_reader :active_tab

  def initialize(active_tab: nil, **html_options)
    @active_tab = active_tab
    @html_options = html_options
  end

  def container_classes
    [
      "border-b border-zinc-200",
      @html_options[:class]
    ].compact.join(" ")
  end

  class TabComponent < ViewComponent::Base
    attr_reader :id, :label, :active

    def initialize(id:, label:, active: false, **html_options)
      @id = id
      @label = label
      @active = active
      @html_options = html_options
    end

    def tab_classes
      base = "inline-flex items-center gap-2 border-b-2 px-4 py-2 text-sm font-medium transition-colors"

      if @active
        "#{base} border-blue-600 text-blue-600"
      else
        "#{base} border-transparent text-zinc-600 hover:border-zinc-300 hover:text-zinc-900"
      end
    end

    def call
      content_tag(:button, type: "button", class: tab_classes, **@html_options) do
        @label
      end
    end
  end
end
