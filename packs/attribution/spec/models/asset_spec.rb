# frozen_string_literal: true

require "rails_helper"

RSpec.describe Attribution::Asset, type: :model do
  describe "associations" do
    it { should have_many(:renders).class_name("Attribution::Render") }
  end

  describe "validations" do
    it "requires a sha256" do
      asset = build(:attribution_asset, sha256: nil)

      expect(asset).not_to be_valid
      expect(asset.errors[:sha256]).to be_present
    end

    it "rejects a sha256 that is not 64 hex characters" do
      [ "", "abc", "z" * 64, "A" * 64, "#{'a' * 63}" ].each do |bad|
        expect(build(:attribution_asset, sha256: bad)).not_to be_valid
      end
    end

    it "accepts a 64-character lowercase hex digest" do
      expect(build(:attribution_asset, sha256: "a" * 64)).to be_valid
    end

    it "rejects a duplicate sha256" do
      digest = Digest::SHA256.hexdigest("one image")
      create(:attribution_asset, sha256: digest)

      expect(build(:attribution_asset, sha256: digest)).not_to be_valid
    end

    it "rejects a kind outside image/video" do
      expect(build(:attribution_asset, kind: "gif")).not_to be_valid
    end
  end

  describe "content addressing on sha256" do
    it "resolves one row per distinct content, however many renders produced it" do
      digest = Digest::SHA256.hexdigest("identical bytes")

      first = described_class.record(sha256: digest, path: "/tmp/a.png", byte_size: 10)
      second = described_class.record(sha256: digest, path: "/tmp/b.png", byte_size: 10)

      expect(second).to eq(first)
      expect(described_class.where(sha256: digest).count).to eq(1)
    end

    it "lets two renders of the same content share one asset" do
      asset = create(:attribution_asset)
      run_one = create(:attribution_render, asset: asset, checkpoint: "CRPv18_PM25.safetensors")
      run_two = create(:attribution_render, asset: asset, checkpoint: "CRPv18_PM40.safetensors")

      expect(asset.renders).to contain_exactly(run_one, run_two)
    end

    it "does not treat the path as identity" do
      digest = Digest::SHA256.hexdigest("bytes")
      create(:attribution_asset, sha256: digest, path: "/tmp/reused.png")

      # A re-used path is a new asset when the bytes differ -- path is a location,
      # not an identity, so it is deliberately NOT unique.
      expect(described_class.record(sha256: Digest::SHA256.hexdigest("other bytes"),
                                    path: "/tmp/reused.png")).to be_persisted
      expect(described_class.where(path: "/tmp/reused.png").count).to eq(2)
    end
  end

  describe "unknown attribution stays unknown" do
    it "finds nothing for content that was never recorded" do
      expect(described_class.for_path("/mnt/nas/never-recorded.png")).to be_nil
      expect(described_class.for_sha256(Digest::SHA256.hexdigest("never recorded"))).to be_nil
    end
  end

  describe "the compliance ledger is not part of this table" do
    # Red line (PRD 0002): photos.provenance is the synthetic-mark COMPLIANCE
    # record. Mixing it into the attribution spine would make a legal record
    # collateral damage of an experiment migration.
    it "carries no provenance/embedded column" do
      expect(described_class.column_names).not_to include("provenance", "embedded", "synthetic")
    end
  end
end
