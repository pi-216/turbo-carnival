# frozen_string_literal: true

namespace :attribution do
  # Join elo-picker's taste verdicts into the spine on `sha256` (read-only).
  #
  # Records elo/rd/wins/losses/draws as Assessment rows on the renders that produced
  # each asset. FAIL-OPEN: an absent or unreachable rating records nothing and is never
  # an error -- elo-picker is never a blocker for posting. Additive and idempotent: a
  # re-run refreshes recorded values where elo-picker still holds a rating.
  #
  # One reader is opened for the whole run (so the DB connection is not per-asset), and
  # closed at the end. ENV override: ELO_PICKER_DATABASE=<postgresql:// URI>.
  desc "Join elo-picker ratings on sha256 into the spine (read-only, never gates posting)"
  task join_elo_ratings: :environment do
    reader = Attribution::EloPickerReader.new
    # Only assets that produced a render can carry an assessment: the join is on the
    # render -> asset edge, so assets with no render have nothing to record against.
    assets = Attribution::Asset.where(id: Attribution::Render.select(:asset_id).distinct)
                               .includes(:renders).order(:id)

    total = 0
    with_rating = 0
    recorded = 0

    assets.find_each do |asset|
      total += 1
      result = Attribution::RecordEloRating.call(sha256: asset.sha256, reader: reader)
      with_rating += 1 if result.rating
      recorded += 1 if result.recorded
    rescue StandardError => e
      warn "attribution:join_elo_ratings failed for #{asset.sha256}: #{e.message}"
    end

    puts "attribution:join_elo_ratings assets=#{total} with_rating=#{with_rating} recorded=#{recorded}"
  ensure
    reader.close
  end
end
