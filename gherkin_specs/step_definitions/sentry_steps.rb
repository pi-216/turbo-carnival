# frozen_string_literal: true

# PRD 0006 R7 · ticket #83. Mirrors spec/initializers/sentry_spec.rb: the
# initialiser enables staging/production only, so capture is shown by putting a
# DSN in front of it, moving the environment into a configured one, and
# re-loading the initialiser. Non-Rails behaviour is never exercised here —
# this stays inside the Rails app's own contract.
#
# No RSpec mocks: the per-test lifecycle does not exist in cucumber, so the DSN
# is stubbed with a singleton method on the cached credentials object and the
# environment is driven via SENTRY_ENVIRONMENT (the initialiser reads it).
Given('a DSN is present in encrypted credentials') do
  reset_sentry_globals!
  creds = Rails.application.credentials
  creds.singleton_class.send(:define_method, :sentry_dsn) do
    'https://public@o213028.ingest.us.sentry.io/4512283302297600'
  end
end

Given('the application runs in a configured environment') do
  ENV['SENTRY_ENVIRONMENT'] = 'production'
end

When('an exception is raised') do
  load Rails.root.join('config/initializers/sentry.rb')
  setup_sentry_test
  raised = begin
    raise 'charter telemetry smoke'
  rescue RuntimeError => e
    e
  end
  Sentry.capture_exception(raised)
end

Then('an event is captured') do
  expect(last_sentry_event).not_to be_nil
  expect(extract_sentry_exceptions(last_sentry_event).first.type).to eq('RuntimeError')
end
