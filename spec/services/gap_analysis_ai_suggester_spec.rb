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

  # Layer 3 (tickets #27/#64): prior proposals are fed into the prompt so the brain
  # avoids repeating what is already on the board.
  it 'feeds prior proposal titles and keywords into the prompt' do
    pillar = build(:content_pillar, name: 'Food & Cooking')
    persona = build(:persona)
    prior = build(:content_suggestion, content_pillar: pillar,
                  gap_analysis: build(:gap_analysis),
                  title: 'Rooftop Brunch', description: 'already proposed',
                  prompt_data: { 'keywords' => %w[rooftop] })

    fresh = [ {
      'name' => 'New Idea', 'description' => 'fresh', 'keywords' => %w[new], 'example_content' => 'x'
    } ].to_json

    prompt_seen = nil
    brain = instance_double(AI::BrainClient, available?: true)
    allow(AI::BrainClient).to receive(:new).and_return(brain)
    allow(brain).to receive(:generate) { |user, **| prompt_seen = user; fresh }

    suggestions = described_class.suggest(pillar: pillar, persona: persona, existing_suggestions: [ prior ])

    expect(prompt_seen).to include('Rooftop Brunch')
    expect(prompt_seen).to include('rooftop')
    expect(suggestions.first[:name]).to eq('New Idea')
  end

  # PRD 0007 A3: the planner prompt carries the ACTUAL ruling instead of the old
  # de-authorizing line ("wardrobe intensity and the persona's age read are founder
  # rulings"). The prompt is the only place the nightly-planning seat learns this —
  # Growth::NightlyPlanner hands it one pillar at a time — so it states the persona
  # is an 18-year-old adult, intensity is in scope up to the legal floor + measured
  # platform boundary, Instagram is the discovery surface for explicit monetization,
  # and the pillar set is fair game. No line tells the brain intensity is off-limits.
  it 'carries the actual ruling: 18-year-old adult, intensity in scope, funnel mandate, pillar set fair game' do
    pillar = build(:content_pillar, name: 'Food & Cooking')
    persona = build(:persona)

    system_seen = nil
    brain = instance_double(AI::BrainClient, available?: true)
    allow(AI::BrainClient).to receive(:new).and_return(brain)
    allow(brain).to receive(:generate) { |_user, system:, **| system_seen = system; '[]' }

    described_class.suggest(pillar: pillar, persona: persona)

    ruling = system_seen.gsub(/\s+/, ' ') # assert across line wraps
    expect(ruling).to include('18-year-old adult')
    expect(ruling).to include('legal floor and the measured platform boundary')
    expect(ruling).to include('discovery surface for explicit monetization')
    expect(ruling).to include('visual gain over personality')
    expect(ruling).to include('fair game')
    # The de-authorizing line is gone, not softened:
    expect(system_seen).not_to include('founder rulings')
    expect(system_seen).not_to include('not yours to move')
  end

  # PRD 0007 A3: the blank "Core Topics" line is filled from the persona's live
  # pillar set (the actual pillars) — not invented, not the empty caption_config.
  it 'fills Core Topics from the persona pillar set, not the blank caption_config' do
    persona = create(:persona)
    create(:content_pillar, persona: persona, name: 'Fashion & Style', active: true)
    create(:content_pillar, persona: persona, name: 'Food & Cooking', active: true)
    pillar = persona.content_pillars.find_by(name: 'Fashion & Style')
    persona.caption_config = Personas::CaptionConfig.new(tone: 'warm', style: 'conversational') # carries no topics

    system_seen = nil
    brain = instance_double(AI::BrainClient, available?: true)
    allow(AI::BrainClient).to receive(:new).and_return(brain)
    allow(brain).to receive(:generate) { |_user, system:, **| system_seen = system; '[]' }

    described_class.suggest(pillar: pillar, persona: persona)

    core_topics = system_seen.lines.map(&:strip).find { |l| l.start_with?('Core Topics:') }
    expect(core_topics).to be_present
    expect(core_topics).to match(/Core Topics:\s*.+/) # not blank — the pillar set is present
    expect(core_topics).to include('Fashion & Style')
    expect(core_topics).to include('Food & Cooking')
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
