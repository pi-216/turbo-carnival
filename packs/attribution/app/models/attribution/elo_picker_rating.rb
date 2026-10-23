# frozen_string_literal: true

module Attribution
  # A single read of elo-picker's `images` row for one sha256 -- the taste verdict the
  # spine joins in. Plain value, no DB: it is the shape the reader returns and the
  # command records.
  #
  # Absent is represented by the READER returning nil, never by a zero here: an
  # unmeasured rating and a measured zero are different facts, and collapsing them
  # manufactures data.
  class EloPickerRating
    attr_reader :sha256, :elo, :rd, :wins, :losses, :draws, :games_played

    def initialize(sha256:, elo:, rd:, wins:, losses:, draws:, games_played:)
      @sha256 = sha256
      @elo = elo
      @rd = rd
      @wins = wins
      @losses = losses
      @draws = draws
      @games_played = games_played
    end
  end
end
