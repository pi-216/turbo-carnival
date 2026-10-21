# frozen_string_literal: true

require 'rails_helper'

# The asset-side half of PRD 0007 B3: the realism scores are MEASUREMENTS ON THE ASSET,
# not only on the run that produced it -- the selection layer orders the pool off these
# columns (Photos::ListAvailable), and the founder's ruling keeps a below-default asset
# for re-valuation, which needs the numbers to survive on the photo.
RSpec.describe ContentPillars::Photo, 'realism measurement columns' do
  let(:persona) { create(:persona) }
  let(:pillar) { create(:content_pillar, persona: persona) }

  def photo_row!(path: nil)
    ContentPillars::Photo.create!(
      persona: persona, content_pillar: pillar, synthetic: true,
      path: path || Rails.root.join('tmp', "realism_asset_spec_#{SecureRandom.hex(6)}.png").to_s
    )
  end

  describe '#record_realism_score' do
    it 'writes both scores' do
      photo = photo_row!

      photo.record_realism_score(aesthetic_score: 6.5, sharpness: 512.4)

      expect(photo.reload.aesthetic_score).to eq(6.5)
      expect(photo.sharpness).to eq(512.4)
    end

    it 'records a measured LOW score rather than leaving it nil' do
      photo = photo_row!

      photo.record_realism_score(aesthetic_score: 3.1, sharpness: 9.4)

      # nil means "never measured"; a measured low score must not read as unknown.
      expect(photo.reload.aesthetic_score).to eq(3.1)
      expect(photo.sharpness).to eq(9.4)
    end

    it 'writes nothing when the score is nil (unmeasured is not a measurement)' do
      photo = photo_row!

      photo.record_realism_score(aesthetic_score: nil, sharpness: nil)

      expect(photo.reload.aesthetic_score).to be_nil
      expect(photo.sharpness).to be_nil
    end

    it 'keeps an existing measurement instead of clobbering it' do
      photo = photo_row!
      photo.record_realism_score(aesthetic_score: 6.5, sharpness: 512.4)

      photo.record_realism_score(aesthetic_score: 2.0, sharpness: 1.0)

      expect(photo.reload.aesthetic_score).to eq(6.5)
      expect(photo.sharpness).to eq(512.4)
    end
  end

  describe '.import_render' do
    it 'carries both scores onto the new asset row' do
      photo = described_class.import_render(
        path: Rails.root.join('tmp', "realism_import_spec_#{SecureRandom.hex(6)}.png").to_s,
        persona: persona, content_pillar: pillar,
        aesthetic_score: 6.5, sharpness: 512.4
      )

      expect(photo.reload.aesthetic_score).to eq(6.5)
      expect(photo.sharpness).to eq(512.4)
    end

    # The interrupted-producer case RenderSalvage exists for: the row is already there,
    # so the measurement has to be BACKFILLED rather than dropped on the floor.
    it 'backfills the scores on the idempotent path' do
      path = Rails.root.join('tmp', "realism_backfill_spec_#{SecureRandom.hex(6)}.png").to_s
      existing = photo_row!(path: path)

      described_class.import_render(path: path, persona: persona, content_pillar: pillar,
                                    aesthetic_score: 3.4, sharpness: 11.0)

      expect(existing.reload.aesthetic_score).to eq(3.4)
      expect(existing.sharpness).to eq(11.0)
    end
  end
end
