# frozen_string_literal: true

module Growth
  # Top-level harness orchestrator: ensures a goal exists, then runs the full
  # loop (snapshot → cadence → review) for the active goal(s) of a persona.
  class Harness
    DEFAULT_PERSONA_NAME = 'Sarah'

    attr_reader :persona

    def initialize(persona_name: nil)
      @persona = find_persona(persona_name)
    end

    def run_all
      return { error: "Persona not found" } unless persona

      goal = Growth::Goal.active.for_persona(persona).order(created_at: :desc).first
      goal ||= Growth::Goal.create!(persona: persona, instagram_handle: persona_handle)

      {
        goal: goal,
        snapshot: Growth::MetricsCollector.new(goal: goal).collect,
        cadence: Growth::CadenceEngine.new(goal: goal).sync,
        review: Growth::StrategyBrain.new(goal: goal).review
      }
    end

    def self.ensure_goal_for_all_personas
      Persona.find_each.map do |p|
        goal = Growth::Goal.active.for_persona(p).first
        next :exists if goal

        Growth::Goal.create!(persona: p, instagram_handle: p.name.downcase.delete(' '))
        :created
      end
    end

    private

    def find_persona(name)
      return Persona.find_by(name: name) if name

      Persona.find_by(name: self.class::DEFAULT_PERSONA_NAME) || Persona.first
    end

    def persona_handle
      persona_attr = persona.try(:instagram_handle)
      return persona_attr if persona_attr.present?

      persona.name.to_s.downcase.gsub(/[^a-z0-9_]/, '')[/.{0,30}/]
    end
  end
end
