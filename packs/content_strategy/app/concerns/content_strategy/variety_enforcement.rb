# frozen_string_literal: true

module ContentStrategy
  module VarietyEnforcement
    def enforce_variety_rules(pillars)
      config = context.config
      eligible = pillars.dup

      # Note: Content pillars don't have a direct relationship to history records yet
      # For now, return all pillars as eligible
      # TODO: Implement pillar-based variety tracking if needed

      eligible
    end

    private

    def least_recently_used_pillar(pillars)
      # Simple fallback: return first pillar
      pillars.first
    end
  end
end
