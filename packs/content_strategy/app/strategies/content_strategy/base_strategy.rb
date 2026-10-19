# frozen_string_literal: true

module ContentStrategy
  class BaseStrategy
    include TimingOptimization
    include VarietyEnforcement

    attr_reader :context

    def initialize(context:)
      @context = context
    end

    def select_next_photo
      raise NotImplementedError, "#{self.class.name} must implement #select_next_photo"
    end

    def name
      self.class.name.demodulize.underscore
    end

    protected

    def select_hashtags(photo:, pillar:)
      HashtagEngine.generate(
        photo: photo,
        pillar: pillar,
        count: context.config.hashtag_count_max
      )
    end

    def recommend_format(photo:, config:)
      # Simple default: prefer carousel format
      { format: 'carousel', rationale: 'Default recommendation' }
    end
  end
end
