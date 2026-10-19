# frozen_string_literal: true

# A flexible card container component with slots for header, body, and footer.
#
# @example Basic card with body content
#   <%= render CardComponent.new do |c| %>
#     <% c.with_body do %>
#       <p>Card content here</p>
#     <% end %>
#   <% end %>
#
# @example Card with header, body, and footer
#   <%= render CardComponent.new(classes: "shadow-xl") do |c| %>
#     <% c.with_header do %>
#       <h3>Card Title</h3>
#     <% end %>
#     <% c.with_body do %>
#       <p>Card content</p>
#     <% end %>
#     <% c.with_footer do %>
#       <button>Action</button>
#     <% end %>
#   <% end %>
class CardComponent < ApplicationComponent
  renders_one :header
  renders_one :body
  renders_one :footer

  # @param classes [String] additional CSS classes to append to the card
  def initialize(classes: "")
    @classes = classes
  end

  private

  def card_classes
    base_classes = "bg-gray-800 rounded-lg overflow-hidden"
    [ base_classes, @classes ].join(" ")
  end

  def header_classes
    "px-4 py-3 bg-gray-800 border-b border-gray-700"
  end

  def body_classes
    "p-4"
  end

  def footer_classes
    "px-4 py-3 bg-gray-800 border-t border-gray-700"
  end
end
