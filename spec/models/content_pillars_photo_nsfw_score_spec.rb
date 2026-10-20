# frozen_string_literal: true

require 'rails_helper'

# The asset-side half of PRD 0007 A1: the NSFW score is a MEASUREMENT ON THE ASSET,
# not only on the run that produced it -- the selection layer, the founder's tier
# pre-flight and any later re-valuation all ask about the photo, and a library photo
# can be spent years after its render.
RSpec.describe ContentPillars::Photo, 'nsfw measurement columns' do
  let(:persona) { create(:persona) }
  let(:pillar) { create(:content_pillar, persona: persona) }

  def photo_row!(path: nil)
    ContentPillars::Photo.create!(
      persona: persona, content_pillar: pillar, synthetic: true,
      path: path || Rails.root.join('tmp', "nsfw_asset_spec_#{SecureRandom.hex(6)}.png").to_s
    )
  end

  describe '#record_nsfw_score' do
    it 'writes the score and the flag of record' do
      photo = photo_row!

      photo.record_nsfw_score(nsfw_score: 0.9992, nsfw_flagged: true)

      expect(photo.reload.nsfw_score).to be_within(0.0001).of(0.9992)
      expect(photo.nsfw_flagged).to be(true)
    end

    it 'records a measured CLEAR score as false rather than leaving it nil' do
      photo = photo_row!

      photo.record_nsfw_score(nsfw_score: 0.02, nsfw_flagged: false)

      # nil means "never measured"; a measured low score must not read as unknown.
      expect(photo.reload.nsfw_score).to be_within(0.0001).of(0.02)
      expect(photo.nsfw_flagged).to be(false)
    end

    it 'writes nothing when the score is nil (unmeasured is not a measurement)' do
      photo = photo_row!

      photo.record_nsfw_score(nsfw_score: nil, nsfw_flagged: nil)

      expect(photo.reload.nsfw_score).to be_nil
      expect(photo.nsfw_flagged).to be_nil
    end

    # The stored flag is the verdict OF RECORD: re-scoring under a revised threshold
    # is the explicit re-valuation the founder's ruling refers to, never a side effect
    # of a second import or a library spend.
    it 'keeps an existing measurement instead of clobbering it' do
      photo = photo_row!
      photo.record_nsfw_score(nsfw_score: 0.9992, nsfw_flagged: true)

      photo.record_nsfw_score(nsfw_score: 0.11, nsfw_flagged: false)

      expect(photo.reload.nsfw_score).to be_within(0.0001).of(0.9992)
      expect(photo.nsfw_flagged).to be(true)
    end
  end

  describe '.import_render' do
    let(:path) do
      p = Rails.root.join('tmp', "nsfw_import_spec_#{SecureRandom.hex(6)}.png").to_s
      FileUtils.mkdir_p(File.dirname(p))
      File.binwrite(p, 'not-really-a-png')
      p
    end

    after { FileUtils.rm_f(path) }

    it 'persists the score on the created asset row' do
      photo = described_class.import_render(
        path: path, persona: persona, content_pillar: pillar,
        nsfw_score: 0.97, nsfw_flagged: true
      )

      expect(photo.reload.nsfw_score).to be_within(0.0001).of(0.97)
      expect(photo.nsfw_flagged).to be(true)
    end

    # The idempotent path is the interrupted-producer case Growth::RenderSalvage
    # exists for: the row already exists, so the re-measured score has to be
    # BACKFILLED rather than dropped on the floor.
    it 'backfills a score onto an asset row that was imported before it was measured' do
      photo = described_class.import_render(path: path, persona: persona, content_pillar: pillar)
      expect(photo.nsfw_score).to be_nil

      same = described_class.import_render(
        path: path, persona: persona, content_pillar: pillar,
        nsfw_score: 0.97, nsfw_flagged: true
      )

      expect(same.id).to eq(photo.id)
      expect(described_class.count).to eq(1)
      expect(photo.reload.nsfw_score).to be_within(0.0001).of(0.97)
      expect(photo.nsfw_flagged).to be(true)
    end

    it 'leaves the score unmeasured when no measurement was taken' do
      photo = described_class.import_render(path: path, persona: persona, content_pillar: pillar)

      expect(photo.reload.nsfw_score).to be_nil
      expect(photo.nsfw_flagged).to be_nil
    end
  end
end
