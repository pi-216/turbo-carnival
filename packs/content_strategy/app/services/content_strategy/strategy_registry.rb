# frozen_string_literal: true

module ContentStrategy
  class StrategyRegistry
    class << self
      def register(name, strategy_class)
        strategies[name.to_sym] = strategy_class
      end

      def get(name)
        strategies[name.to_sym] || raise(UnknownStrategyError.new(name, all))
      end

      def exists?(name)
        strategies.key?(name.to_sym)
      end

      def all
        strategies.keys
      end

      def clear!
        @strategies = {}
      end

      private

      def strategies
        @strategies ||= {}
      end
    end
  end
end
