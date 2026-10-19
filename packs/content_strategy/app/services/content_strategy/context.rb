# frozen_string_literal: true

module ContentStrategy
  class Context
    attr_reader :persona, :pillar, :pillars, :history, :state, :config

    def initialize(persona:, pillar: nil)
      @persona = persona
      @pillar = pillar
      @config = ConfigLoader
      load_context
    end

    def selected_pillar
      @pillar
    end

    private

    def load_context
      @pillars = load_pillars
      @history = load_history
      @state = load_state
    end

    def load_pillars
      base_scope = @persona.content_pillars.active.current

      # Filter to specific pillar if provided
      base_scope = base_scope.where(id: @pillar.id) if @pillar

      # Only pillars with unposted photos (using persona-scoped query)
      base_scope
        .joins(:photos)
        .where.not(photos: { id: Scheduling::Post.where(persona_id: @persona.id).select(:photo_id).where.not(photo_id: nil) })
        .distinct
        .order(:name)
    end

    def load_history
      HistoryRecord
        .for_persona(@persona.id)
        .recent_days(30)
        .includes(:post)
        .recent
    end

    def load_state
      StrategyState.find_or_create_by!(persona: @persona) do |state|
        state.active_strategy = @config.default_strategy
        state.started_at = Time.current
      end
    end
  end
end
