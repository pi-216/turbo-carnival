# frozen_string_literal: true

require "rails_helper"

# A fake PG result that answers `exec_params` with a canned row set. The reader is
# connection-injected so these specs never touch elo-picker's real DB.
class FakePqResult
  def initialize(rows)
    @rows = rows
  end

  def to_a
    @rows
  end
end

class FakePqConnection
  def initialize(rows)
    @rows = rows
  end

  def exec_params(_sql, _params)
    FakePqResult.new(@rows)
  end
end

class RaisingPqConnection
  def exec_params(_sql, _params)
    raise PG::ConnectionBad, "elo-picker is unreachable"
  end
end

RSpec.describe Attribution::EloPickerReader do
  let(:row) do
    { "sha256" => "a" * 64, "elo" => 8120.0, "rd" => 210.0, "wins" => 14,
      "losses" => 3, "draws" => 1, "games_played" => 18 }
  end

  describe "#rating_for" do
    it "returns the rating row for a sha256 elo-picker holds" do
      reader = described_class.new(connection: FakePqConnection.new([ row ]))

      rating = reader.rating_for("a" * 64)

      expect(rating).to be_a(Attribution::EloPickerRating)
      expect(rating.sha256).to eq("a" * 64)
      expect(rating.elo).to eq(8120.0)
      expect(rating.rd).to eq(210.0)
      expect(rating.wins).to eq(14)
      expect(rating.losses).to eq(3)
      expect(rating.draws).to eq(1)
      expect(rating.games_played).to eq(18)
    end

    # Absent is a normal state for posting: the join returns nil, never a zero.
    it "returns nil when elo-picker holds no rating for the sha256 (never 0)" do
      reader = described_class.new(connection: FakePqConnection.new([]))

      expect(reader.rating_for("a" * 64)).to be_nil
    end

    # Fail-open: an unreachable elo-picker reads as absent, not as an error and not
    # as a posting gate.
    it "returns nil (fail-open) when elo-picker is unreachable, without raising" do
      reader = described_class.new(connection: RaisingPqConnection.new)

      expect(reader.rating_for("a" * 64)).to be_nil
    end

    it "rejects a sha256 that is not a 64-hex digest" do
      reader = described_class.new(connection: FakePqConnection.new([ row ]))

      expect(reader.rating_for("not-a-digest")).to be_nil
      expect(reader.rating_for(nil)).to be_nil
    end
  end
end
