# frozen_string_literal: true

# Gherkin/Cucumber bootstrap. Add helpers and support files in this
# directory (session_helpers.rb, step-specific setup) — this file stays
# minimal. Extend via require or by adding sibling files; Cucumber loads
# everything under support/.
require 'cucumber/rails'

# Add app-specific world setup here, e.g.:
# World(SomeHelpers)
