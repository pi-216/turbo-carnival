# frozen_string_literal: true

# PRD 0007 A1 (ticket #104): the NSFW classifier is an ADVISORY measurement, and the
# measurement lives on the ASSET row -- not only in `pipeline_runs.quality_metrics`.
#
# WHY the asset: every consumer of the flag asks a question about the ASSET ("which
# photos crossed the border?", "may the tier pre-flight look at this one?"), and the
# run is not always reachable from it (a library photo spent years after its render,
# a candidate-imported photo with no run at all). The score must also survive a
# threshold change as the verdict OF RECORD: re-scoring is an explicit act, so the
# stored flag is never silently recomputed under a new threshold.
#
# Both columns are NULLABLE with NO default, on purpose: NULL means UNMEASURED (the
# photo was imported on a path that ran no classifier, or the gate failed open), which
# is a different statement from `false` (measured below the threshold). Same rule as
# `photos.synthetic` -- unknown is not a verdict.
#
# NO INDEX: `photos` is a few hundred rows and every consumer already filters by
# persona / created_at first, so an index would buy nothing and cost a concurrent
# build. Add one only with a measured query that needs it.
class AddNsfwAdvisoryToPhotos < ActiveRecord::Migration[8.0]
  def change
    add_column :photos, :nsfw_score, :float
    add_column :photos, :nsfw_flagged, :boolean
  end
end
