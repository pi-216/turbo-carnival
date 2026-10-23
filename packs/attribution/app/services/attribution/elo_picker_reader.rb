# frozen_string_literal: true

require "pg"

module Attribution
  # Read-only client for elo-picker's `images` table, joined on sha256 -- the same key
  # the spine uses. Taste verdicts (elo, rd, wins, losses, draws) live there; this is
  # how the spine reads them in, and it writes nothing back.
  #
  # FAIL-OPEN BY DESIGN: an absent rating, and an unreachable elo-picker, both read as
  # nil -- never as a zero, and never as an error. elo-picker is never a blocker for
  # posting; the day-to-day path must complete unaffected whether it is up or down.
  #
  # READ-ONLY BY CONSTRUCTION: the connection opens with `default_transaction_read_only
  # = on`, so every statement in the session is server-enforced read-only. The join
  # cannot write back into elo-picker even if a future caller tries.
  #
  # The connection is injectable (a fake in specs) so these paths never need elo-picker's
  # real DB to be reachable.
  class EloPickerReader
    # Local dev default: elo-picker's own database.yml uses `username: tim` on the same
    # postgres this app uses. ENV override: ELO_PICKER_DATABASE=<postgresql:// URI>.
    DEFAULT_DATABASE = "postgresql://tim@localhost/elo_picker_development"
    READ_ONLY_OPTIONS = "-c default_transaction_read_only=on"
    RATING_COLUMNS = %w[sha256 elo rd wins losses draws games_played].freeze

    def self.rating_for(sha256)
      reader = new
      reader.rating_for(sha256)
    ensure
      reader&.close
    end

    def initialize(connection: nil, database: ENV.fetch("ELO_PICKER_DATABASE", DEFAULT_DATABASE))
      @connection = connection
      @database = database
      @owned = nil
    end

    # Returns an EloPickerRating, or nil when elo-picker holds no rating for the digest
    # or is unreachable. Never returns 0 for an absent rating, never raises to a caller.
    def rating_for(sha256)
      return nil unless sha256&.match?(Attribution::Asset::SHA256_FORMAT)

      row = fetch_row(sha256)
      return nil unless row

      build_rating(row)
    rescue PG::Error, URI::InvalidURIError => e
      warn_unreachable(e)
      nil
    end

    # Releases the owned connection (an injected one is the caller's to close).
    def close
      @owned&.close
      @owned = nil
    end

    private

    def connection
      @connection || (@owned ||= open_connection)
    end

    def open_connection
      PG::Connection.open(
        dbname: uri.path.to_s.delete_prefix("/"),
        user: uri.user || "tim",
        host: uri.host || "localhost",
        options: READ_ONLY_OPTIONS
      )
    end

    def uri
      @uri ||= URI.parse(@database)
    end

    def fetch_row(sha256)
      result = connection.exec_params(
        "SELECT #{RATING_COLUMNS.join(", ")} FROM images WHERE sha256 = $1 LIMIT 1",
        [ sha256 ]
      )
      result.to_a.first
    end

    def build_rating(row)
      EloPickerRating.new(
        sha256: row["sha256"], elo: row["elo"], rd: row["rd"],
        wins: row["wins"], losses: row["losses"], draws: row["draws"],
        games_played: row["games_played"]
      )
    end

    def warn_unreachable(error)
      Rails.logger.warn("elo-picker unreachable; ratings read as absent: #{error.message}")
    end
  end
end
