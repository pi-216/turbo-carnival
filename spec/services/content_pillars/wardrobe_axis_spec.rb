# frozen_string_literal: true

require 'rails_helper'

# PRD 0007 A2 (#105): the wardrobe axis. This is the content-config home for
# the per-pillar reveal level — the scale it runs on and the "current validated
# tier" that bounds it (the ceiling the pre-flight, A5, pushes up rung by rung).
# These are pure decisions, so they are tested without a DB or a render.
RSpec.describe ContentPillars::WardrobeAxis do
  around do |ex|
    ENV.delete(described_class::VALIDATED_TIER_ENV)
    ex.run
  ensure
    ENV.delete(described_class::VALIDATED_TIER_ENV)
  end

  describe 'the scale' do
    it 'spans the reveal range, from a covered floor to minimal coverage' do
      expect(described_class::MAX_LEVEL).to be >= 8
      expect(described_class::LADDER.first).to match(/fully covered/i)
      expect(described_class::LADDER.last).to match(/minimal coverage|bikini/i)
    end

    it 'is a coverage statement at every rung, not a mood word' do
      described_class::LADDER.each do |rung|
        expect(rung).to match(/wearing/i), "rung is not a coverage statement: #{rung}"
      end
    end

    it "maps the miniskirt rung to the founder's wording" do
      expect(described_class::LADDER[described_class::MINISKIRT_LEVEL - 1]).to match(/miniskirt/i)
    end

    it 'carries no old SFW-only floor' do
      expect(described_class::LADDER.join(' ')).not_to match(/modest everyday clothing/i)
    end
  end

  describe '.validated_tier' do
    it 'defaults to the expected-pass anchor (the knee-length rung)' do
      expect(described_class.validated_tier).to eq(2)
    end

    context 'when the env override names a rung' do
      before { ENV[described_class::VALIDATED_TIER_ENV] = '5' }

      it 'reads the override' do
        expect(described_class.validated_tier).to eq(5)
      end
    end

    context 'when the env override is above the scale' do
      before { ENV[described_class::VALIDATED_TIER_ENV] = '999' }

      it 'clamps to the scale max' do
        expect(described_class.validated_tier).to eq(described_class::MAX_LEVEL)
      end
    end

    it 'is the same value as .ceiling (one source for the bound)' do
      expect(described_class.ceiling).to eq(described_class.validated_tier)
    end
  end

  describe '.on_scale?' do
    it 'accepts every rung on the ladder' do
      (described_class::MIN_LEVEL..described_class::MAX_LEVEL).each do |n|
        expect(described_class.on_scale?(n)).to be(true)
      end
    end

    it 'rejects out-of-range and non-integer values' do
      expect(described_class.on_scale?(0)).to be(false)
      expect(described_class.on_scale?(described_class::MAX_LEVEL + 1)).to be(false)
      expect(described_class.on_scale?(nil)).to be(false)
      expect(described_class.on_scale?('5')).to be(false)
    end
  end

  describe '.effective_level' do
    it 'falls back to the floor when the pillar is unconfigured' do
      expect(described_class.effective_level(double('pillar', wardrobe_level: nil))).to eq(1)
      expect(described_class.effective_level(nil)).to eq(1)
    end

    it 'honours the pillar rung when it is at or below the tier' do
      allow(described_class).to receive(:validated_tier).and_return(5)
      expect(described_class.effective_level(double('pillar', wardrobe_level: 3))).to eq(3)
    end

    it 'clamps a rung above the tier down to the tier' do
      allow(described_class).to receive(:validated_tier).and_return(2)
      expect(described_class.effective_level(double('pillar', wardrobe_level: 8))).to eq(2)
    end
  end

  describe '.descriptor_for_pillar' do
    it 'returns the coverage for the effective level' do
      allow(described_class).to receive(:validated_tier).and_return(5)
      expect(described_class.descriptor_for_pillar(double('pillar', wardrobe_level: 5))).to match(/miniskirt/i)
    end

    it 'uses the covered floor for an unconfigured pillar' do
      expect(described_class.descriptor_for_pillar(double('pillar', wardrobe_level: nil))).to match(/fully covered/i)
    end
  end
end
