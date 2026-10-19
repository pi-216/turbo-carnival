# frozen_string_literal: true

# Register content strategies at application boot
Rails.application.config.to_prepare do
  # Load strategy files
  Dir[Rails.root.join("packs/content_strategy/app/**/*.rb")].each do |file|
    require_dependency file
  end

  # Register strategies
  ContentStrategy::StrategyRegistry.register(
    :thematic_rotation_strategy,
    ContentStrategy::ThematicRotationStrategy
  )

  ContentStrategy::StrategyRegistry.register(
    :theme_of_week_strategy,
    ContentStrategy::ThemeOfWeekStrategy
  )
end
