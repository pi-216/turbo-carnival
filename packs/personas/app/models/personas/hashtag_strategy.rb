# frozen_string_literal: true

module Personas
  class HashtagStrategy
    attr_reader :max_tags, :brand_tags, :strategy_type, :errors
    attr_writer :brand_tags

    def initialize(attributes = {})
      @max_tags = attributes[:max_tags] || attributes['max_tags'] || 10
      @brand_tags = attributes[:brand_tags] || attributes['brand_tags'] || []
      @strategy_type = attributes[:strategy_type] || attributes['strategy_type']
      @errors = []
      validate
    end

    # ContentStrategy::HashtagEngine reads `strategy.tags` (falling back to
    # strategy['tags'] for a Hash). This class exposed only `brand_tags`, so
    # NEITHER branch of the engine could ever match and the persona's configured
    # strategy was unreachable -- the reason every published post carried zero
    # hashtags even though the strategy existed and was populated.
    def tags
      Array(@brand_tags)
    end

    def valid?
      @errors.empty?
    end

    def to_hash
      {
        max_tags: @max_tags,
        brand_tags: @brand_tags,
        strategy_type: @strategy_type
      }.compact
    end

    def self.from_hash(hash)
      new(hash)
    end

    private

    def validate
      if @max_tags && (@max_tags < 1 || @max_tags > 30)
        @errors << "max_tags must be between 1 and 30"
      end
    end
  end
end
