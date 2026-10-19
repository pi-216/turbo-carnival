# frozen_string_literal: true

# Extensions to the cucumber World for the harness scenarios (PRD 0006 R5/R7,
# ticket #83). env.rb stays minimal and byte-identical to the template; the
# env.rb comment directs extensions to sibling support files.
#
# Sentry::TestHelper gives the capture assertions (setup_sentry_test /
# last_sentry_event / ...). RSpec mocks are deliberately NOT wired in — the
# per-test lifecycle does not exist in cucumber (OutsideOfExampleError), so
# the Sentry steps drive the initialiser with a credentials singleton method
# + SENTRY_ENVIRONMENT instead.
require 'sentry/test_helper'

World(Sentry::TestHelper)
