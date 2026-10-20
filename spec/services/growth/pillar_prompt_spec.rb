# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Growth::PillarPrompt do
  KNOWN_PILLARS = %i[food travel fitness wellness beauty lifestyle fashion].freeze

  describe 'content-strategy fix (2026-10-08)' do
    it 'gives every known pillar a large, distinct scene pool' do
      described_class::SCENES.each do |key, pool|
        expect(pool.size).to be >= 12, "#{key} has only #{pool.size} scenes"
      end
    end

    it 'has no duplicate scene strings within any pillar pool (variety is real, not paraphrases)' do
      described_class::SCENES.each do |key, pool|
        expect(pool.size).to eq(pool.uniq.size), "#{key} pool contains duplicate scenes"
      end
    end

    it 'expands the distinct-prompt space far beyond the old 18 (sampling yields hundreds of distinct prompts)' do
      pillar_names = %w[Food\ &\ Cooking Travel\ &\ Adventure Fitness\ &\ Wellness] + KNOWN_PILLARS.map(&:to_s)
      prompts = []
      pillar_names.each do |name|
        pillar = build(:content_pillar, name: name)
        200.times { prompts << described_class.for_pillar(pillar) }
      end
      expect(prompts.uniq.size).to be >= 200
    end

    it 'every FRAMING keeps the face in frame (CLIPSeg head node needs a region)' do
      described_class::FRAMINGS.each do |framing|
        expect(framing).to match(/face|head|portrait|shoulders/i), "framing without a face marker: #{framing}"
      end
    end

    it 'every sampled prompt embeds a face-in-frame framing and the axis floor (unconfigured)' do
      KNOWN_PILLARS.each do |key|
        pillar = build(:content_pillar, name: key.to_s)
        described_class::SCENES[key].size.times do
          prompt = described_class.for_pillar(pillar)
          expect(prompt).to match(/face|head|portrait|shoulders/i)
          # An unconfigured pillar renders at the axis FLOOR (covered) — a rung
          # the brain can raise, not a hardcoded SFW constraint (PRD 0007 A2).
          expect(prompt).to match(/wearing everyday clothing|fully covered/i)
          expect(prompt).not_to match(/lingerie|bralette|bikini|see-through/i)
        end
      end
    end
  end

  describe 'the wardrobe axis (PRD 0007 A2, #105)' do
    it 'has no hardcoded SFW clothing floor in the constant path' do
      expect(described_class::BASE).not_to match(/modest everyday clothing|fully dressed/i)
    end

    it 'embeds the covered floor for an unconfigured pillar' do
      pillar = build(:content_pillar, name: 'Food & Cooking', wardrobe_level: nil)
      prompt = described_class.for_pillar(pillar)
      expect(prompt).to match(/wearing everyday clothing, torso and legs fully covered/i)
    end

    it 'embeds the miniskirt rung when the pillar is set to it and the tier allows it' do
      allow(ContentPillars::WardrobeAxis).to receive(:validated_tier).and_return(5)
      pillar = build(:content_pillar, name: 'Food & Cooking', wardrobe_level: 5)
      prompt = described_class.for_pillar(pillar)
      expect(prompt).to match(/short miniskirt/i)
      expect(prompt).to match(/torso covered/i)
    end

    it 'embeds the bikini rung once the tier has been validated up to it' do
      allow(ContentPillars::WardrobeAxis).to receive(:validated_tier).and_return(8)
      pillar = build(:content_pillar, name: 'Fashion & Style', wardrobe_level: 8)
      prompt = described_class.for_pillar(pillar)
      expect(prompt).to match(/two-piece bikini/i)
    end

    it 'clamps a rung above the current validated tier down to the tier' do
      allow(ContentPillars::WardrobeAxis).to receive(:validated_tier).and_return(2)
      pillar = build(:content_pillar, name: 'Fashion & Style', wardrobe_level: 8)
      prompt = described_class.for_pillar(pillar)
      expect(prompt).to match(/knee-length skirt/i)
      expect(prompt).not_to match(/bikini|miniskirt/i)
    end

    it 'carries no SFW-only default in the prompt path (the scene pools are wardrobe-agnostic)' do
      forbidden = /trench coat|blazer|blouse|button[- ]up|mid-length dress|knit (sweater|dress)|plain (casual )?tee|casual (clothes|outfit|look)|sportswear|fully dressed|modest/i
      targets = [ described_class::BASE, described_class::DEFAULT_SCENES ] + described_class::SCENES.values
      targets.flatten.each do |text|
        expect(text).not_to match(forbidden), "prompt path carries an SFW wardrobe default: #{text}"
      end
    end

    it 'a non-SFW wardrobe prompt is not contradicted by a scene outfit' do
      allow(ContentPillars::WardrobeAxis).to receive(:validated_tier).and_return(8)
      pillar = build(:content_pillar, name: 'Fashion & Style', wardrobe_level: 8)
      prompt = described_class.for_pillar(pillar)
      expect(prompt).to match(/two-piece bikini/i)
      expect(prompt).not_to match(/trench coat|blazer|mid-length dress|knit sweater|button-up|blouse|sportswear|plain tee/i)
    end
  end

  describe '.for_pillar' do
    def embeds_pool_scene?(prompt, pool)
      pool.any? { |s| prompt.include?(s) }
    end

    it 'maps Food & Cooking to a food-pool scene (no fashion/beauty drift)' do
      pillar = build(:content_pillar, name: 'Food & Cooking')
      prompt = described_class.for_pillar(pillar)
      expect(embeds_pool_scene?(prompt, described_class::SCENES[:food])).to be(true), "prompt not from food pool: #{prompt}"
      expect(prompt).not_to match(/trench|lingerie|bralette|beach/i)
    end

    it 'maps Travel & Adventure to a travel-pool scene' do
      pillar = build(:content_pillar, name: 'Travel & Adventure')
      prompt = described_class.for_pillar(pillar)
      expect(embeds_pool_scene?(prompt, described_class::SCENES[:travel])).to be(true), "prompt not from travel pool: #{prompt}"
    end

    it 'resolves Fitness & Wellness to :fitness bank, not :wellness (tie-break)' do
      pillar = build(:content_pillar, name: 'Fitness & Wellness')
      prompt = described_class.for_pillar(pillar)
      expect(embeds_pool_scene?(prompt, described_class::SCENES[:fitness])).to be(true), "prompt not from fitness pool: #{prompt}"
      expect(embeds_pool_scene?(prompt, described_class::SCENES[:wellness])).to be(false), "prompt from wellness pool: #{prompt}"
    end

    it 'falls back to DEFAULT_SCENES for unknown pillars' do
      pillar = build(:content_pillar, name: 'Science Lectures')
      prompt = described_class.for_pillar(pillar)
      expect(embeds_pool_scene?(prompt, described_class::DEFAULT_SCENES)).to be(true), "prompt not from default pool: #{prompt}"
    end

    it 'never emits an NSFW-adjacent wardrobe token from any known bank' do
      %w[food travel wellness fitness beauty lifestyle fashion cooking].each do |key|
        pillar = build(:content_pillar, name: "#{key.capitalize} & Co")
        prompt = described_class.for_pillar(pillar)
        expect(prompt).not_to match(/lingerie|bralette|bikini|see-through|sheer(?!s)/i)
      end
    end
  end
end
