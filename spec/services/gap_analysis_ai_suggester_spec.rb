# frozen_string_literal: true

require 'rails_helper'

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

  it 'falls back to template suggestions when no AI key is configured' do
    pillar = build(:content_pillar, name: 'Food & Cooking')
    persona = build(:persona)

    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('GEMINI_API_KEY').and_return(nil)

    suggestions = described_class.suggest(pillar: pillar, persona: persona)

    expect(suggestions).to be_an(Array)
    expect(suggestions).not_to be_empty
    expect(suggestions.first[:source]).to eq('template')
    expect(suggestions.first[:name]).to include('Food & Cooking')
  end
end