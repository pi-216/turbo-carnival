# frozen_string_literal: true

require 'rails_helper'

# The per-pillar wardrobe axis is stored on the pillar (PRD 0007 A2, #105).
# The data layer validates the SCALE (a rung on ContentPillars::WardrobeAxis);
# the dynamic "current validated tier" ceiling is enforced by the growth layer,
# so the model stays valid for every rung the brain has ever set.
RSpec.describe ContentPillar do
  let(:persona) { create(:persona) }

  describe 'wardrobe_level' do
    it 'is unconfigured (nil) by default' do
      expect(build(:content_pillar, persona: persona).wardrobe_level).to be_nil
    end

    it 'accepts any rung on the scale' do
      (ContentPillars::WardrobeAxis::MIN_LEVEL..ContentPillars::WardrobeAxis::MAX_LEVEL).each do |n|
        expect(build(:content_pillar, persona: persona, wardrobe_level: n)).to be_valid, "level #{n} should be valid"
      end
    end

    it 'rejects a level below the scale floor' do
      pillar = build(:content_pillar, persona: persona, wardrobe_level: 0)
      expect(pillar).not_to be_valid
      expect(pillar.errors[:wardrobe_level]).to include('must be 1..8')
    end

    it 'rejects a level above the scale max' do
      pillar = build(:content_pillar, persona: persona, wardrobe_level: 99)
      expect(pillar).not_to be_valid
      expect(pillar.errors[:wardrobe_level]).to be_present
    end
  end
end
