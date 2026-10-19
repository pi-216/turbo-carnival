# frozen_string_literal: true

require 'sentry/test_helper'

# Brings the Sentry SDK up under a DUMMY dsn so a spec can assert what the pillar actually
# hands to the transport, then tears it back down.
#
# The teardown is the important half: the SDK is a process-global, so an example that left it
# initialized would hand every later example a live client with a real ingestion host, and the
# first captured exception in the suite would try to POST to sentry.io.
RSpec.shared_context 'with sentry telemetry' do
  before do
    Sentry::TestHelper.reset_sentry_globals!
    Sentry.init do |config|
      config.dsn = 'https://public@o1.ingest.us.sentry.io/1'
      config.environment = 'production'
      config.enabled_environments = %w[production]
      config.background_worker_threads = 0
    end
    Sentry::TestHelper.setup_sentry_test
  end

  after do
    Sentry::TestHelper.teardown_sentry_test
    Sentry::TestHelper.reset_sentry_globals!
  end

  # The metrics the code under test emitted, as the SDK would send them: each item is a Hash
  # with :name, :type (:counter / :gauge / :distribution), :value and :attributes.
  # Attribute values are serialized as { value:, type: }.
  def emitted_metrics
    Sentry::TestHelper.sentry_metrics
  end

  # One emitted metric by name, or nil when it was never emitted -- so a spec can fail with
  # "no such metric" instead of a NoMethodError on nil.
  def metric(name)
    emitted_metrics.find { |m| m[:name] == name }
  end
end
