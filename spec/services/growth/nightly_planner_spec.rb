# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib', 'ai', 'brain_client')

RSpec.describe Growth::NightlyPlanner do
  let(:persona) { create(:persona) }
  let!(:pillar) { create(:content_pillar, persona: persona, active: true, weight: 10, priority: 3) }
  let!(:goal) { create(:growth_goal, persona: persona) }

  let(:payload) do
    [ {
      'name' => 'Rooftop Brunch',
      'description' => 'Sunlit weekend brunch on a rooftop',
      'keywords' => %w[brunch rooftop],
      'example_content' => 'A laid-back rooftop brunch scene'
    } ].to_json
  end

  def stub_brain(available:)
    brain = double('brain', available?: available)
    allow(brain).to receive(:generate).and_return(payload) if available
    allow(AI::BrainClient).to receive(:new).and_return(brain)
  end

  it 'plans and persists proposals when the seat is up' do
    stub_brain(available: true)

    result = nil
    expect { result = described_class.new(persona_name: persona.name).call }
      .to change(ContentSuggestion, :count).by_at_least(1)

    expect(result.seat_up).to be(true)
    expect(result.written?).to be(true)
    expect(Growth::Decision.where(action: 'brain_planned').count).to eq(1)
  end

  # LAYER 1 — window idempotence: one plan per persona per night.
  it 'is idempotent for the night: a second run without force writes nothing' do
    stub_brain(available: true)
    described_class.new(persona_name: persona.name).call
    before = ContentSuggestion.count

    result = described_class.new(persona_name: persona.name).call

    expect(result.seat_up).to be(true)
    expect(result.skipped_personas).to eq(1)
    expect(result.suggestions).to eq(0)
    expect(ContentSuggestion.count).to eq(before)
  end

  it 're-plans on the same night when forced' do
    stub_brain(available: true)
    described_class.new(persona_name: persona.name).call

    result = described_class.new(persona_name: persona.name, force: true).call

    expect(result.skipped_personas).to eq(0)
    expect(result.personas).to eq(1)
  end

  # LAYER 2 — write-time dedupe: a title already on the board is not re-added.
  it 'drops a proposal whose title already exists for the pillar' do
    gap = create(:gap_analysis, persona: persona, recommendations: { 'created_by' => 'other' })
    create(:content_suggestion, gap_analysis: gap, content_pillar: pillar,
                                title: 'Rooftop Brunch', description: 'already on the board')
    stub_brain(available: true)

    result = described_class.new(persona_name: persona.name).call

    expect(result.suggestions).to eq(0)
    expect(ContentSuggestion.where(content_pillar: pillar).count).to eq(1)
  end

  it 'writes nothing and is not an error when the seat is down (fail-soft)' do
    stub_brain(available: false)

    before = [ ContentSuggestion.count, Growth::Decision.where(action: 'brain_planned').count ]
    result = described_class.new(persona_name: persona.name).call

    expect(result.seat_up).to be(false)
    expect(result.written?).to be(false)
    expect(ContentSuggestion.count).to eq(before[0])
    expect(Growth::Decision.where(action: 'brain_planned').count).to eq(before[1])
  end

  it 'records the seat that produced the proposals on the gap analysis' do
    stub_brain(available: true)
    described_class.new(persona_name: persona.name).call

    gap = GapAnalysis.order(:id).last
    expect(gap.recommendations['created_by']).to eq('brain_nightly')
    expect(gap.recommendations['endpoint']).to eq(AI::BrainClient.config[:endpoint])
  end
end
