# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Growth::PillarPrompt do
  describe '.for_pillar' do
    it 'maps Food & Cooking to a food scene (no fashion/beauty drift)' do
      pillar = build(:content_pillar, name: 'Food & Cooking')
      prompt = described_class.for_pillar(pillar)
      expect(prompt).to match(/kitchen|counter|charcuterie|dough|sauce/)
      expect(prompt).not_to match(/trench|beach|evening|lingerie|bralette/)
    end

    it 'maps Travel & Adventure to a travel scene' do
      pillar = build(:content_pillar, name: 'Travel & Adventure')
      prompt = described_class.for_pillar(pillar)
      expect(prompt).to match(/daypack|journal|street map|landmark/)
    end

    it 'resolves Fitness & Wellness to :fitness bank, not :wellness (tie-break)' do
      pillar = build(:content_pillar, name: 'Fitness & Wellness')
      prompt = described_class.for_pillar(pillar)
      expect(prompt).to match(/run|rope/)
      expect(prompt).not_to match(/yoga|herbal tea/)
    end

    it 'falls back to DEFAULT_SCENES for unknown pillars' do
      pillar = build(:content_pillar, name: 'Science Lectures')
      prompt = described_class.for_pillar(pillar)
      expect(prompt).to match(/boardwalk|reading nook/)
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
