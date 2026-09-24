# frozen_string_literal: true

module ContentStrategy
  class SelectNextPost
    attr_reader :persona, :strategy_name

    def initialize(persona:, strategy_name: nil)
      @persona = persona
      @strategy_name = strategy_name || default_strategy_name
    end

    def call
      validate_strategy!

      context = build_context
      strategy = build_strategy(context)

      result = strategy.select_next_photo

      if result[:error]
        { success: false, error: result[:error] }
      else
        {
          success: true,
          photo: result[:photo],
          pillar: result[:pillar] || context.selected_pillar,
          optimal_time: result[:optimal_time],
          hashtags: result[:hashtags],
          format: result[:format],
          strategy_name: strategy.name
        }
      end
    rescue UnknownStrategyError, NoAvailableClustersError, NoUnpostedPhotosError => e
      { success: false, error: e.message }
    end

    private

    def validate_strategy!
      unless StrategyRegistry.exists?(strategy_name)
        raise UnknownStrategyError.new(strategy_name, StrategyRegistry.all)
      end
    end

    def build_context
      # Select pillar first if persona has active pillars
      pillar = select_pillar_if_applicable
      Context.new(persona: persona, pillar: pillar)
    end

    def build_strategy(context)
      strategy_class = StrategyRegistry.get(strategy_name)
      strategy_class.new(context: context)
    end

    def default_strategy_name
      state = StrategyState.find_by(persona: persona)
      state&.active_strategy || ConfigLoader.default_strategy
    end

    def select_pillar_if_applicable
      # Future: integrate with content pillars rotation if needed
      # For now, return nil
      nil
    end
  end
end
