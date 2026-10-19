# frozen_string_literal: true

module ContentStrategy
  class ThemeOfWeekStrategy < BaseStrategy
    def select_next_photo
      # Get current week number
      current_week = Date.current.cweek
      state_week = context.state.get_state(:week_number)

      # If new week or no state, select new pillar
      if state_week.nil? || current_week != state_week
        select_pillar_for_new_week(current_week)
      end

      # Get pillar from state
      pillar_id = context.state.get_state(:pillar_id)
      pillar = context.pillars.find { |p| p.id == pillar_id }

      # If pillar exhausted or not found, advance to next
      if pillar.nil? || pillar.photos.unposted.empty?
        select_pillar_for_new_week(current_week)
        pillar_id = context.state.get_state(:pillar_id)
        pillar = context.pillars.find { |p| p.id == pillar_id }
      end

      raise NoAvailableClustersError.new(context.persona.id) if pillar.nil? # TODO: Rename to NoAvailablePillarsError

      # Get unposted photos from this week's pillar using command
      result = Photos::ListAvailable.call(persona: context.persona, pillar_id: pillar.id)
      unposted_photos = result.photos

      raise NoUnpostedPhotosError.new("in pillar #{pillar.name}") if unposted_photos.empty?

      # Select random photo from pillar
      photo = unposted_photos.sample

      # Build result
      {
        photo: photo,
        pillar: pillar,
        optimal_time: get_optimal_posting_time(photo: photo),
        hashtags: select_hashtags(photo: photo, pillar: pillar),
        format: recommend_format(photo: photo, config: context.config)
      }
    end

    private

    def select_pillar_for_new_week(week_number)
      all_pillars = context.pillars.to_a
      raise NoAvailableClustersError.new(context.persona.id) if all_pillars.empty? # TODO: Rename to NoAvailablePillarsError

      # Get last used pillar index
      last_index = context.state.get_state(:last_pillar_index) || -1

      # Select next pillar (round-robin)
      new_index = (last_index + 1) % all_pillars.size
      pillar = all_pillars[new_index]

      # Update state
      context.state.update_state(
        week_number: week_number,
        pillar_id: pillar.id,
        last_pillar_index: new_index
      )
    end
  end
end
