# frozen_string_literal: true

module ContentStrategy
  class StrategyAdjuster < GLCommand::Callable
    def call
      persona = Persona.find_by(name: "Sarah")
      return unless persona

      state = ContentStrategy::StrategyState.find_by(persona: persona)
      return unless state

      scores = state.pillar_engagement_scores || {}
      return if scores.empty?

      adjust_pillar_weights(persona, scores)
      log_changes(persona)
    end

    private

    def adjust_pillar_weights(persona, scores)
      pillars = persona.content_pillars.where(active: true)
      return if pillars.empty?

      # Only adjust if we have enough data (at least 14 days of posts)
      total_posts = Scheduling::Post
        .where(persona_id: persona.id, status: "posted")
        .where("posted_at > ?", 14.days.ago)
        .count
      return if total_posts < 5

      # Compute target weights based on engagement scores
      total_score = scores.values.sum
      return if total_score.zero?

      target_weights = {}
      pillars.each do |pillar|
        score = scores[pillar.name] || 50
        target_weights[pillar.id] = (score / total_score * 100).round(1)
      end

      # Normalize to sum exactly 100
      diff = 100 - target_weights.values.sum
      # Distribute remainder to highest-scoring pillar
      if diff != 0
        top_pillar = target_weights.max_by { |_, w| w }&.first
        target_weights[top_pillar] = (target_weights[top_pillar] + diff).round(1) if top_pillar
      end

      # Apply weights (with 5% floor, 30% ceiling)
      changes = []
      pillars.each do |pillar|
        new_weight = target_weights[pillar.id].clamp(5, 30)
        old_weight = pillar.weight

        if (new_weight - old_weight).abs >= 2 # Only update if meaningful change
          pillar.update!(weight: new_weight)
          changes << { pillar: pillar.name, old: old_weight, new: new_weight }
        end
      end

      # Normalize again after clamping
      total = pillars.sum(&:weight)
      if total != 100
        diff = 100 - total
        top = pillars.max_by(&:weight)
        top.update!(weight: (top.weight + diff).round(1)) if top
      end

      state.update!(last_adjustment: changes, last_adjustment_at: Time.current)
    end

    def log_changes(persona)
      state = ContentStrategy::StrategyState.find_by(persona: persona)
      changes = state&.last_adjustment
      return unless changes.is_a?(Array) && changes.any?

      puts "StrategyAdjuster: updated #{changes.size} pillar weights"
      changes.each do |c|
        direction = c[:new] > c[:old] ? "↑" : "↓"
        puts "  #{c[:pillar]}: #{c[:old]}% → #{c[:new]}% #{direction}"
      end
    end
  end
end
