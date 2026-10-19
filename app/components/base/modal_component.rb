# frozen_string_literal: true

class Base::ModalComponent < ViewComponent::Base
  attr_reader :id, :size, :title

  def initialize(id:, size: :md, title: nil, **html_options)
    @id = id
    @size = size
    @title = title
    @html_options = html_options
  end

  def modal_classes
    [
      "fixed inset-0 z-50 hidden overflow-y-auto",
      @html_options[:class]
    ].compact.join(" ")
  end

  def dialog_classes
    base = "relative mx-auto my-8 rounded-lg bg-white shadow-xl"
    size_class = case @size
    when :sm then "max-w-md"
    when :md then "max-w-lg"
    when :lg then "max-w-2xl"
    when :xl then "max-w-4xl"
    when :full then "max-w-7xl"
    else "max-w-lg"
    end

    "#{base} #{size_class}"
  end

  def backdrop_id
    "#{@id}-backdrop"
  end
end
