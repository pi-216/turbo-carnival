# frozen_string_literal: true

module ContentStrategy
  class NoAvailableClustersError < StandardError
    def initialize(persona_id)
      @persona_id = persona_id
      super("No available content pillars for persona #{@persona_id}. Please create content pillars with photos first.")
    end
  end
end
