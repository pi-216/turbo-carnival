# frozen_string_literal: true

require 'rails_helper'

# The review engine's levers are bounded EXPERIMENTS: `applied_changes` is what
# the next week's gate evaluation reads to decide whether a lever worked and
# should be kept or reverted. A lever that moves nothing but records a change
# anyway therefore corrupts the experiment ledger — measured on review 5
# (2026-09-14): `caption action=warmer` recorded `from == to` on a persona whose
# tone was "friendly and approachable" (free text, never equal to the literal
# 'friendly' the lever tested for), so no caption knob moved and nothing said so.
#
# `change[:kind]` is a SYMBOL in memory and a STRING once the review round-trips
# through jsonb, so assertions compare `.to_s`.
RSpec.describe Growth::PersonaEvolution do
  subject(:evolution) { described_class.new(goal: goal) }

  let(:persona) { create(:persona) }
  let(:goal) { create(:growth_goal, persona: persona) }

  describe '#adjust_caption' do
    context 'when the persona already reads warm and intimate (the measured review-5 case)' do
      let(:persona) do
        create(:persona).tap do |p|
          p.caption_config = { tone: 'friendly and approachable', style: 'intimate',
                               voice: 'warm, authentic, conversational' }
          p.save!
        end
      end

      it 'records NOTHING — a change that changes nothing is not an experiment' do
        result = evolution.adjust_caption(:warmer)

        expect(result).to be_nil
        expect(evolution.changes).to be_empty
      end

      it 'leaves the authored voice untouched' do
        evolution.adjust_caption(:warmer)

        expect(persona.reload.caption_config.tone).to eq('friendly and approachable')
        expect(persona.reload.caption_config.style).to eq('intimate')
      end
    end

    context 'when the tone does not already read as warm' do
      let(:persona) do
        create(:persona).tap do |p|
          p.caption_config = { tone: 'professional and polished', style: 'casual' }
          p.save!
        end
      end

      it 'warms the tone and adds the intimate style, recording ONE real change' do
        change = evolution.adjust_caption(:warmer)

        expect(change[:kind].to_s).to eq('caption_config')
        expect(change[:from]).not_to eq(change[:to])
        expect(change[:from]).to eq(tone: 'professional and polished', style: 'casual')
        expect(change[:to]).to eq(tone: 'professional and polished, warm', style: 'intimate')
        expect(persona.reload.caption_config.tone).to eq('professional and polished, warm')
      end

      it 'is idempotent — a second :warmer is inert, not a second experiment' do
        evolution.adjust_caption(:warmer)
        second = described_class.new(goal: goal).adjust_caption(:warmer)

        expect(second).to be_nil
        expect(persona.reload.caption_config.tone).to eq('professional and polished, warm')
      end
    end

    it 'replaces the tone outright for the discrete actions (:bolder/:calmer/:balanced)' do
      persona.caption_config = { tone: 'friendly', style: 'casual' }
      persona.save!

      expect(evolution.adjust_caption(:bolder)[:to]).to eq(tone: 'confident', style: 'bold')
    end
  end

  describe '#adjust_hashtags' do
    context 'at the TAG_MIN floor (a tighten that cannot move)' do
      let(:persona) do
        create(:persona).tap do |p|
          p.hashtag_strategy = { max_tags: 3, brand_tags: [ 'test' ] }
          p.save!
        end
      end

      it 'records nothing rather than a no-op experiment' do
        result = evolution.adjust_hashtags(posts: 10, engagement: 9.0)

        expect(result).to be_nil
        expect(evolution.changes).to be_empty
      end
    end

    it 'records a real broaden when there is room to move' do
      persona.hashtag_strategy = { max_tags: 5, brand_tags: [ 'test' ] }
      persona.save!

      change = evolution.adjust_hashtags(posts: 10, engagement: 0.2)

      expect(change[:kind].to_s).to eq('hashtag_strategy')
      expect(change[:to][:max_tags]).to eq(10)
      expect(change[:from]).not_to eq(change[:to])
    end

    # The 10 -> 30 ramp (reviews 2-5) bought no engagement; the lever is now
    # capped at the baseline so a low-engagement week cannot re-walk it.
    it 'does NOT broaden above the baseline' do
      persona.hashtag_strategy = { max_tags: 10, brand_tags: [ 'test' ] }
      persona.save!

      expect(evolution.adjust_hashtags(posts: 10, engagement: 0.2)).to be_nil
      expect(evolution.changes).to be_empty
    end
  end

  describe '#enforce_tag_baseline' do
    it 'pulls an above-baseline tag volume back to the baseline and records why' do
      persona.hashtag_strategy = { max_tags: 30, brand_tags: [ 'test' ] }
      persona.save!

      change = evolution.enforce_tag_baseline

      expect(persona.reload.hashtag_strategy.max_tags).to eq(10)
      expect(change[:kind].to_s).to eq('hashtag_strategy')
      expect(change[:from][:max_tags]).to eq(30)
      expect(change[:to][:max_tags]).to eq(10)
      expect(change[:reason]).to include('baseline')
    end

    it 'is a no-op at or below the baseline (records nothing)' do
      expect(evolution.enforce_tag_baseline).to be_nil
      expect(evolution.changes).to be_empty
    end
  end

  describe '#reweight_toward_top' do
    let!(:top) { create(:content_pillar, persona: persona, name: 'Fashion & Style', weight: 20, priority: 3) }
    let!(:bottom) { create(:content_pillar, persona: persona, name: 'Food & Cooking', weight: 20, priority: 3) }

    it 'returns exactly the two content_pillar records (reward + penalty)' do
      pillars = [
        { name: 'Fashion & Style', posts: 5, engagement: 3.0 },
        { name: 'Food & Cooking', posts: 5, engagement: 0.1 }
      ]

      changes = evolution.reweight_toward_top(pillars)

      expect(changes.size).to eq(2)
      expect(changes.map { |c| c[:kind].to_s }).to all(eq('content_pillar'))
      expect(changes.map { |c| c[:reason] }).to contain_exactly('reward Fashion & Style', 'penalize Food & Cooking')
      expect(changes).to all(satisfy { |c| c[:from] != c[:to] })
    end
  end
end
