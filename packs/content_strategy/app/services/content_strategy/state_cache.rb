# frozen_string_literal: true

module ContentStrategy
  class StateCache
    TTL = 5.minutes

    class << self
      def fetch(persona_id, &block)
        Rails.cache.fetch(cache_key(persona_id), expires_in: TTL, &block)
      end

      def invalidate(persona_id)
        Rails.cache.delete(cache_key(persona_id))
      end

      private

      def cache_key(persona_id)
        "content_strategy/state/persona_#{persona_id}"
      end
    end
  end
end
