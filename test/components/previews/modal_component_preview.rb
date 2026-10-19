# frozen_string_literal: true

# @label Base/Modal
class ModalComponentPreview < ViewComponent::Preview
  # @label Default
  def default
    render(Base::ModalComponent.new(id: "example-modal", title: "Modal Title")) do
      "This is the modal content. You can put any content here."
    end
  end

  # @label With Footer
  def with_footer
    component = Base::ModalComponent.new(id: "modal-with-footer", title: "Confirm Action")

    render_with_template(
      template: "modal_component_preview/with_footer",
      locals: { component: component }
    )
  end

  # @label All Sizes
  def all_sizes
    render_with_template(template: "modal_component_preview/all_sizes")
  end

  # @label Form Example
  def form_example
    component = Base::ModalComponent.new(id: "form-modal", title: "Create New Item", size: :lg)

    render_with_template(
      template: "modal_component_preview/form_example",
      locals: { component: component }
    )
  end
end
