# frozen_string_literal: true

module ContentStrategy
  class UnknownStrategyError < StandardError
    def initialize(strategy_name, available_strategies)
      @strategy_name = strategy_name
      @available_strategies = available_strategies
      super(message)
    end

    def message
      "Unknown strategy: #{@strategy_name}. Available: #{@available_strategies.join(', ')}"
    end
  end
end
