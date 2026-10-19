# frozen_string_literal: true

class CreatePersona < GLCommand::Callable
  requires :name
  returns :persona

  validates :name, presence: true

  def call
    context.persona = Persona.create!(name: context.name)
  end

  def rollback
    context.persona&.destroy
  end
end
