# frozen_string_literal: true

# PRD 0007 B3 (ticket #110): the realism measurement is ADVISORY, and like the NSFW
# score (A1) it lives on the ASSET row -- not only in `pipeline_runs.quality_metrics`.
#
# WHY the asset: every consumer of these scores asks a question about the ASSET ("which
# of these may I spend first?", "what did the founder want kept for re-valuation?"), and
# the run is not always reachable from it (a library photo spent months after its render,
# a candidate-imported photo with no run at all). The asset row is also the only place a
# reserve-ordering query can read.
#
# Both columns are NULLABLE with NO default, on purpose: NULL means UNMEASURED (the photo
# was imported on a path that ran no scorer, or the scorer failed open), which is a
# different statement from 0.0 -- and the selection layer must treat unmeasured as
# "unknown", not as "low quality". Same rule as `photos.synthetic` and `photos.nsfw_score`.
#
# NO `flagged` column, deliberately -- unlike `nsfw_flagged`. The NSFW flag is a compliance
# verdict of record at the threshold then in force; these two are raw MEASUREMENTS and the
# aesthetic/sharpness values are the SELECTION DEFAULTS (4.5 / 30.0), which are meant to be
# re-tunable. Storing the derived flag would freeze a verdict computed under an old default
# and make a threshold change require a re-score to take effect; comparing the stored scores
# against the current defaults at selection time is the honest form of "overridable".
#
# NO INDEX: `photos` is a few hundred rows and every consumer already filters by persona /
# created_at first, so an index would buy nothing and cost a concurrent build.
class AddRealismAdvisoryToPhotos < ActiveRecord::Migration[8.0]
  def change
    add_column :photos, :aesthetic_score, :float
    add_column :photos, :sharpness, :float
  end
end
