# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib', 'ai', 'brain_client')

# Regression spec for a namespace collision that NOTHING else in the suite could
# see: this class used to be `GapAnalysis::AiSuggester`, and `GapAnalysis` is an
# ActiveRecord model -- a CLASS, not a module. So `module GapAnalysis` in the
# pack raised `TypeError: GapAnalysis is not a module` the moment both were
# loaded, which (a) aborted eager loading, meaning `RAILS_ENV=production` could
# not boot the app or run a task at all, and (b) made the pillar `#suggest`
# action answer "Error generating suggestions: GapAnalysis is not a module"
# instead of suggestions. rspec never eager-loads and the running service is
# development (lazy loading), so the suite stayed green throughout.
RSpec.describe GapAnalysisAi::Suggester do
  it 'resolves while the GapAnalysis model is loaded (no namespace collision)' do
    expect(defined?(GapAnalysis)).to eq('constant')
    expect(GapAnalysis).to be_a(Class)
    expect(described_class).to be_a(Class)
    expect(described_class.name).to eq('GapAnalysisAi::Suggester')
  end

  # Ticket #27: the content planner role talks to the LOCAL UNCENSORED BRAIN.
  it 'plans with the local brain when it is available' do
    pillar = build(:content_pillar, name: 'Food & Cooking')
    persona = build(:persona)
    # The REAL shape: caption_config is a Personas::CaptionConfig object. build_context
    # used to call `.dig('topics')` on it, raising NoMethodError that `suggest` rescued
    # into the template fallback — so the role never reached any model. This guards it.
    persona.caption_config = Personas::CaptionConfig.new(tone: 'warm', style: 'conversational')

    payload = [ {
      'name' => 'Rooftop Brunch',
      'description' => 'A weekend brunch on a sunlit rooftop',
      'keywords' => %w[brunch rooftop sunlight],
      'example_content' => 'A laid-back rooftop brunch scene'
    } ].to_json

    brain = instance_double(AI::BrainClient, available?: true)
    allow(AI::BrainClient).to receive(:new).and_return(brain)
    expect(brain).to receive(:generate)
      .with(anything, system: anything, temperature: 0.8, max_tokens: 1500)
      .and_return(payload)

    suggestions = described_class.suggest(pillar: pillar, persona: persona)

    expect(suggestions.first[:source]).to eq('ai')
    expect(suggestions.first[:name]).to eq('Rooftop Brunch')
  end

  it 'falls back to template suggestions when no planner client is configured' do
    pillar = build(:content_pillar, name: 'Food & Cooking')
    persona = build(:persona)

    allow(AI::BrainClient).to receive(:new).and_return(instance_double(AI::BrainClient, available?: false))
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('GEMINI_API_KEY').and_return(nil)

    suggestions = described_class.suggest(pillar: pillar, persona: persona)

    expect(suggestions).to be_an(Array)
    expect(suggestions).not_to be_empty
    expect(suggestions.first[:source]).to eq('template')
    expect(suggestions.first[:name]).to include('Food & Cooking')
  end
end
