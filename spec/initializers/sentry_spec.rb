# frozen_string_literal: true

require 'rails_helper'
require 'sentry/test_helper'

# PRD 0006 R7 · ticket #77. The initialiser is the whole pillar: with a DSN it must come up
# and capture an event; with no DSN it must stay silent without costing a boot error.
#
# Two states have to be driven explicitly rather than observed. The suite itself boots with
# NO DSN (that is the initialiser's own rule for dev/test), so "it captures" can only be
# shown by putting a DSN in front of it and moving Rails into a CONFIGURED environment --
# the initialiser enables `staging`/`production` only, so an example running under the real
# RAILS_ENV (test) could never capture by construction.
RSpec.describe 'config/initializers/sentry.rb' do
  include Sentry::TestHelper

  let(:dsn) { 'https://public@o213028.ingest.us.sentry.io/4512283302297600' }
  let(:credentials) { double('credentials') }

  def load_initializer!
    load Rails.root.join('config/initializers/sentry.rb')
  end

  before do
    reset_sentry_globals!
    allow(Rails.application).to receive(:credentials).and_return(credentials)
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new('production'))
  end

  after do
    teardown_sentry_test if Sentry.initialized?
    reset_sentry_globals!
  end

  context 'with a DSN present' do
    before { allow(credentials).to receive(:sentry_dsn).and_return(dsn) }

    it 'initialises the SDK from the credentials DSN, not from the environment' do
      load_initializer!

      expect(Sentry.initialized?).to be(true)
      expect(Sentry.configuration.dsn.to_s).to eq(dsn)
      expect(Sentry.configuration.environment).to eq('production')
    end

    # The assertion the ticket names: an exception raised in a configured environment is
    # captured. Without this, "Sentry is installed" is a gem in a lockfile.
    it 'captures an exception raised in a configured environment' do
      load_initializer!
      setup_sentry_test

      raised = begin
        raise 'charter telemetry smoke'
      rescue RuntimeError => e
        e
      end
      Sentry.capture_exception(raised)

      expect(last_sentry_event).not_to be_nil
      expect(extract_sentry_exceptions(last_sentry_event).first.type).to eq('RuntimeError')
    end
  end

  context 'with no DSN' do
    it 'boots without error and leaves the SDK off' do
      allow(credentials).to receive(:sentry_dsn).and_return(nil)

      expect { load_initializer! }.not_to raise_error
      expect(Sentry.initialized?).to be(false)
    end

    # `present?` is what guards the init, so the empty string counts as absent -- that is the
    # shape a secrets manager hands back for an unset variable, and it must not bring the
    # SDK up pointed at nothing.
    it 'treats an empty DSN as absent' do
      allow(credentials).to receive(:sentry_dsn).and_return('')

      load_initializer!

      expect(Sentry.initialized?).to be(false)
    end
  end
end
