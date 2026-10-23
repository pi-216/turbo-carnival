# frozen_string_literal: true

require "rails_helper"

# Guard for PRD 0002 / ticket #43: "elo-picker is NEVER a blocker for posting".
#
# The join lives in packs/attribution and is fail-open by construction (absent or
# unreachable reads as nil, never 0, never an error). What this spec guards is the
# OTHER direction: no code path in the content pipeline may order or gate its work on
# whether a rating exists. A developer wiring the join into the posting path (or the
# render loop) makes the rating instrument a posting dependency -- the one thing this
# ticket exists to prevent. So the posting source is scanned and asserted to contain
# no reference to the elo-picker join at all.
RSpec.describe "elo-picker is never a posting gate (PRD 0002 / #43)" do
  # The posting path: scheduling commands/rake + the day-to-day post automation under
  # app/commands. The attribution pack itself and its specs are the join's home, so they
  # are deliberately OUT of the scan.
  POSTING_PATHS = %w[packs/scheduling app/commands].freeze
  JOIN_SYMBOLS = %w[EloPickerReader RecordEloRating EloPickerRating].freeze

  it "is referenced nowhere in the posting path" do
    hits = []

    POSTING_PATHS.each do |dir|
      Dir.glob(Rails.root.join(dir, "**/*.rb")).each do |path|
        next if path.include?("/spec/")

        source = File.read(path).gsub(/#.*$/, "") # strip comments so prose does not count
        JOIN_SYMBOLS.each do |symbol|
          hits << "#{path}:#{symbol}" if source.include?(symbol)
        end
      end
    end

    expect(hits).to be_empty,
                    "the posting path must not reference the elo-picker join; found #{hits.join(", ")}"
  end
end
