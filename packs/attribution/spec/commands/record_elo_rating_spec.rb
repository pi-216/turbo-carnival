# frozen_string_literal: true

require "rails_helper"

# A fake elo-picker reader: the command never touches elo-picker's real DB, and the
# absence/unreachable paths are exercised by returning nil.
class FakeEloReader
  def initialize(rating)
    @rating = rating
  end

  def rating_for(_sha256)
    @rating
  end
end

RSpec.describe Attribution::RecordEloRating do
  let(:digest) { "c" * 64 }
  let(:rating) do
    Attribution::EloPickerRating.new(
      sha256: digest, elo: 8120.0, rd: 210.0, wins: 14, losses: 3, draws: 1, games_played: 18
    )
  end

  def call(**overrides)
    described_class.call(
      sha256: digest,
      reader: FakeEloReader.new(rating),
      **overrides
    )
  end

  describe "#call" do
    it "records elo-picker's rating as assessments on the renders that produced the asset" do
      asset = create(:attribution_asset, sha256: digest)
      render_a = create(:attribution_render, asset: asset)
      render_b = create(:attribution_render, asset: asset)

      result = call

      expect(result).to be_success
      expect(result.recorded).to be(true)
      expect(result.rating).to eq(rating)

      expect(Attribution::Assessment.where(render_id: render_a.id, assessor_model: "elo-picker")
                                    .pluck(:metric, :value)).to contain_exactly(
        [ "elo", 8120.0 ], [ "rd", 210.0 ], [ "wins", 14 ], [ "losses", 3 ], [ "draws", 1 ]
      )
      expect(Attribution::Assessment.where(render_id: render_b.id, assessor_model: "elo-picker").count).to eq(5)
    end

    it "is a no-op and succeeds when elo-picker holds no rating (absence is normal, never 0)" do
      asset = create(:attribution_asset, sha256: digest)
      render = create(:attribution_render, asset: asset)

      result = described_class.call(sha256: digest, reader: FakeEloReader.new(nil))

      expect(result).to be_success
      expect(result.recorded).to be(false)
      expect(result.rating).to be_nil
      expect(Attribution::Assessment.count).to eq(0)
    end

    # Fail-open: an unreachable elo-picker reads as absent and must not gate or raise.
    it "is a no-op and succeeds when elo-picker is unreachable" do
      create(:attribution_asset, sha256: digest)

      result = described_class.call(sha256: digest, reader: FakeEloReader.new(nil))

      expect(result).to be_success
      expect(result.recorded).to be(false)
      expect(Attribution::Assessment.count).to eq(0)
    end

    it "records nothing when no asset/render exists for the sha256" do
      result = described_class.call(sha256: digest, reader: FakeEloReader.new(rating))

      expect(result).to be_success
      expect(result.recorded).to be(false)
      expect(Attribution::Assessment.count).to eq(0)
    end

    # A re-read refreshes the current rating: elo-picker's numbers move as votes land, and
    # the join must not treat a re-run as a failure to record.
    it "refreshes an existing assessment value on re-read" do
      asset = create(:attribution_asset, sha256: digest)
      render = create(:attribution_render, asset: asset)
      call

      newer = Attribution::EloPickerRating.new(
        sha256: digest, elo: 8240.0, rd: 190.0, wins: 16, losses: 3, draws: 1, games_played: 20
      )
      result = described_class.call(sha256: digest, reader: FakeEloReader.new(newer))

      expect(result).to be_success
      expect(Attribution::Assessment.find_by(render_id: render.id, metric: "elo").value).to eq(8240.0)
      expect(Attribution::Assessment.where(render_id: render.id, assessor_model: "elo-picker").count).to eq(5)
    end

    it "keys the assessment to the elo-picker assessor so it never collides with another assessor" do
      asset = create(:attribution_asset, sha256: digest)
      render = create(:attribution_render, asset: asset)
      create(:attribution_assessment, render: render, assessor_model: "auraface", metric: "elo", value: 0.5)

      call

      expect(Attribution::Assessment.where(render_id: render.id, assessor_model: "elo-picker", metric: "elo").count).to eq(1)
      expect(Attribution::Assessment.find_by(render_id: render.id, assessor_model: "auraface", metric: "elo").value).to eq(0.5)
    end
  end
end
