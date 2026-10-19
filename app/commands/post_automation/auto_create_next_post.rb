# frozen_string_literal: true

module PostAutomation
  # Chain all steps together to automatically create and schedule the next post
  class AutoCreateNextPost < GLCommand::Chainable
    requires persona: Persona
    allows strategy_name: String

    returns :photo, :pillar, :optimal_time, :hashtags, :format, :strategy_name,
            :caption, :caption_metadata, :post

    chain SelectNextPhoto,
          GenerateCaption,
          CreateScheduledPost
  end
end
