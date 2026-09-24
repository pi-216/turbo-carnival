# frozen_string_literal: true

module ContentStrategy
  class ThematicRotationStrategy < BaseStrategy
    def select_next_photo
      # Get pillars with variety enforcement
      eligible_pillars = enforce_variety_rules(context.pillars.to_a)

      raise NoAvailableClustersError.new(context.persona.id) if eligible_pillars.empty? # TODO: Rename to NoAvailablePillarsError

      # Get rotation index from state
      rotation_index = context.state.get_state(:rotation_index) || 0

      # Select pillar at index (with wrapping)
      pillar = eligible_pillars[rotation_index % eligible_pillars.size]

      # Get unposted photos from this pillar using command
      result = Photos::ListAvailable.call(persona: context.persona, pillar_id: pillar.id)
      unposted_photos = result.photos

      raise NoUnpostedPhotosError.new("in pillar #{pillar.name}") if unposted_photos.empty?

      # Select random photo from pillar
      photo = unposted_photos.sample

      # Update rotation index
      new_index = (rotation_index + 1) % eligible_pillars.size
      context.state.set_state(:rotation_index, new_index)

      # Build result
      {
        photo: photo,
        pillar: pillar,
        optimal_time: get_optimal_posting_time(photo: photo),
        hashtags: select_hashtags(photo: photo, pillar: pillar),
        format: recommend_format(photo: photo, config: context.config)
      }
    end
  end
end
