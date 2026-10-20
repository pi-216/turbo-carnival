# frozen_string_literal: true

module PostAutomation
  # Step 1: Use content strategy to select the next photo to post
  class SelectNextPhoto < ApplicationCommand
    requires persona: Persona
    allows strategy_name: String

    returns :photo, :pillar, :optimal_time, :hashtags, :format, :strategy_name

    def call
      result = ContentStrategy::SelectNextPost.new(
        persona: persona,
        strategy_name: strategy_name
      ).call

      stop_and_fail!("No photos available for posting", no_notify: true) unless result[:success]

      context.photo = result[:photo]
      context.pillar = result[:pillar]
      context.optimal_time = result[:optimal_time]
      context.hashtags = result[:hashtags]
      context.format = result[:format]
      context.strategy_name = result[:strategy_name]
    end
  end
end
