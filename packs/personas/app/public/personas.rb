# frozen_string_literal: true

# The public API for the personas pack.
module Personas
  # Lists all Personas.
  #
  # @return [Array<Persona>] a list of all personas.
  def self.list
    Persona.all.to_a
  end

  # Finds a Persona by their name.
  #
  # @param name [String] the name of the Persona to find.
  # @return [Persona, nil] the found Persona, or nil if not found.
  def self.find_by_name(name:)
    Persona.find_by(name: name)
  end

  # Creates a new Persona.
  #
  # @param name [String] the name of the new Persona.
  # @return [GLCommand::Context] the result of the CreatePersona command.
  def self.create(name:)
    CreatePersona.call(name: name)
  end

  # Finds a Persona by their ID.
  #
  # @param id [Integer] the ID of the Persona to find.
  # @return [Persona, nil] the found Persona, or nil if not found.
  def self.find(id)
    Persona.find_by(id: id)
  end
end
