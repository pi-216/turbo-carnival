# frozen_string_literal: true

require 'rails_helper'

# PRD 0006 R7 · ticket #77. The charter's numbers have to leave the database, or a stated
# number is untracked -- nothing alerts when it stalls. These examples pin the metric NAMES
# and the values behind them, because a dashboard (and the alert built on it) keys off them.
RSpec.describe CharterTelemetry do
  let(:persona) { create(:persona) }
  let(:goal) do
    create(:growth_goal, persona: persona, target_followers: 1000, start_followers: 151)
  end

  context 'with the Sentry pillar live' do
    include_context 'with sentry telemetry'

    it 'emits the live charter reading as gauges' do
      goal.update!(deadline: Date.current + 100.days)

      described_class.emit_goal(goal)

      followers = emitted_metrics.find { |m| m[:name] == 'growth.followers' }
      pace = emitted_metrics.find { |m| m[:name] == 'growth.required_per_day' }

      expect(followers[:type]).to eq(:gauge)
      expect(followers[:value]).to eq(151)
      # (1000 - 151) followers left over 100 days -- the same arithmetic Growth::Goal reports.
      expect(pace[:type]).to eq(:gauge)
      expect(pace[:value]).to be_within(0.001).of(8.49)
    end

    # Asserted as DELTAS against the table counts taken first: an equality against
    # `Model.count` alone would pass with an empty table whatever source was wired, so the
    # rows are created here and each one has to move its own series.
    it 'emits the managed inventory (personas, images, reels, assets) as gauges' do
      # Force the shared `persona` let to exist BEFORE the baseline is read: it is lazy, so
      # its creation would otherwise land inside the window and read as one extra persona.
      persona
      baseline_personas = Persona.count
      baseline_images = ContentPillars::Photo.count
      baseline_reels = Scheduling::Post.where.not(reel_path: nil).count

      create(:persona)
      pillar = create(:content_pillar, persona: persona)
      ContentPillars::Photo.create!(
        persona: persona, content_pillar: pillar,
        path: "/tmp/inventory-spec/#{SecureRandom.hex(6)}.png"
      )
      Scheduling::Post.create!(
        persona: persona, reel_path: "/tmp/inventory-spec/#{SecureRandom.hex(6)}.mp4"
      )

      described_class.emit_inventory

      expect(metric('inventory.personas')[:type]).to eq(:gauge)
      expect(metric('inventory.personas')[:value]).to eq(baseline_personas + 1)
      expect(metric('inventory.images')[:value]).to eq(baseline_images + 1)
      expect(metric('inventory.reels')[:value]).to eq(baseline_reels + 1)
      expect(metric('inventory.assets')[:value]).to eq(baseline_images + baseline_reels + 2)
    end

    it 'emits the pipeline acceptance counter for both outcomes' do
      described_class.emit_pipeline_acceptance(
        accepted: 3, rejected: 1, pillar: 'athleisure'
      )

      accepted = emitted_metrics.find { |m| m[:name] == 'pipeline.render.accepted' }
      rejected = emitted_metrics.find { |m| m[:name] == 'pipeline.render.rejected' }

      expect(accepted[:type]).to eq(:counter)
      expect(accepted[:value]).to eq(3)
      expect(accepted[:attributes][:pillar][:value]).to eq('athleisure')
      expect(rejected[:type]).to eq(:counter)
      expect(rejected[:value]).to eq(1)
    end

    # The attribute has to stay a low-cardinality LABEL. A run id or a path in an attribute
    # explodes the metric index and is a PII leak, so an unknown pillar must emit none.
    # (The SDK stamps its own telemetry attributes -- environment, release, sdk.version,
    # server.address -- onto every metric; only the pillar key is ours to assert on.)
    it 'omits the pillar attribute when there is no pillar to name' do
      described_class.emit_pipeline_acceptance(accepted: 0, rejected: 2)

      accepted = emitted_metrics.find { |m| m[:name] == 'pipeline.render.accepted' }

      expect(accepted[:value]).to eq(0)
      expect(accepted[:attributes]).not_to have_key(:pillar)
    end

    it 'ignores a nil goal rather than raising on a persona with no goal' do
      expect { described_class.emit_goal(nil) }.not_to raise_error
    end
  end

  # The ticket's other half: with no DSN the app boots and emits nothing -- no error, no work.
  # The suite runs in exactly that state, so this is the real configuration and not a stub.
  context 'with no DSN (no SDK initialized)' do
    it 'no-ops without raising' do
      expect(Sentry.initialized?).to be(false)

      expect {
        described_class.emit_goal(goal)
        described_class.emit_pipeline_acceptance(accepted: 3, rejected: 1, pillar: 'athleisure')
      }.not_to raise_error

      expect(Sentry.get_current_client).to be_nil
    end
  end
end
