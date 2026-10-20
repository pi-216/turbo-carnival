# frozen_string_literal: true

# Make the app's FactoryBot definitions and its `create`/`build` syntax available
# to the Cucumber world so a Given step can create real records. cucumber/rails
# boots the app but loads neither the factory definitions nor the syntax methods
# on its own; this mirrors spec/rails_helper.rb's factory_bot_rails setup.
# (Guarded so a definition already loaded by the factory_bot_rails railtie is not
# redefined.)
FactoryBot.find_definitions unless FactoryBot.factories.registered?(:content_pillar)
World(FactoryBot::Syntax::Methods)
