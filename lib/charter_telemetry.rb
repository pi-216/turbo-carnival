# frozen_string_literal: true

# The charter's numbers, emitted rather than stored (PRD 0006 R7 · ticket #77).
#
# The charter is "reach 1000 followers by 2027-08-20". Until this file those numbers lived
# only in `Growth::Goal` rows and a report somebody has to open: a stated number with no
# emitted telemetry is *untracked* — nothing alerts when it stalls, which is the failure the
# charter exists to make visible.
#
# `Sentry::Metrics` returns early unless the SDK is initialized, so every call here is a
# no-op — no error, no work — in dev/test and in any deploy with no DSN (ticket #77 AC:
# "with no DSN the app boots and emits nothing"). Never guard these calls with
# `respond_to?`: a guard that silently skips the emission is how a metric dies quietly.
module CharterTelemetry
  module_function

  # The live charter reading for one goal: where it stands, and the pace it needs.
  # Both come from `Growth::Goal` — the same numbers every trajectory read is built from,
  # so the gauge and the dashboard can never disagree.
  def emit_goal(goal)
    return if goal.nil?

    Sentry::Metrics.gauge("growth.followers", goal.latest_followers)
    Sentry::Metrics.gauge("growth.required_per_day", goal.required_daily_growth)
  end

  # The inventory the venture manages: personas, and media assets (images + reels).
  # Gauges, not counters -- both go DOWN as well as up (assets are pruned, personas are
  # added), and a counter could only ever climb, so it could never show a loss.
  #
  # The definitions live here so a dashboard cannot drift from the database:
  #   personas -> every `Persona` row
  #   images   -> every `ContentPillars::Photo` row (the managed still inventory)
  #   reels    -> every `Scheduling::Post` carrying a `reel_path`, which is that model's own
  #               discriminator for "this is a reel" (`Scheduling::Post#reel?`)
  #   assets   -> images + reels, emitted as its own total so the headline number needs no
  #               client-side sum
  #
  # `Attribution::Asset` is deliberately NOT the count here. It is the content-addressed
  # spine (sha256, kinds image/video) and it is the right join key for attribution, but it is
  # still unpopulated while PRD 0002's spine work is open: reporting 0 managed assets beside
  # 388 stored photos would be a number that contradicts the corpus.
  def emit_inventory
    images = ContentPillars::Photo.count
    reels = Scheduling::Post.where.not(reel_path: nil).count

    Sentry::Metrics.gauge("inventory.personas", Persona.count)
    Sentry::Metrics.gauge("inventory.assets", images + reels)
    Sentry::Metrics.gauge("inventory.images", images)
    Sentry::Metrics.gauge("inventory.reels", reels)
  end

  # The render pipeline's acceptance counter: of the candidates a run ranked, how many were
  # accepted into the photo set and how many were rejected. A gated pipeline with no
  # acceptance counter is a dead pipeline wearing a heartbeat.
  #
  # `pillar` must stay LOW-CARDINALITY — a pillar name is a fixed vocabulary. Never pass a
  # run id, a candidate id or a path: it explodes the metric index and leaks PII.
  def emit_pipeline_acceptance(accepted:, rejected:, pillar: nil)
    attributes = pillar.present? ? { pillar: pillar.to_s } : nil

    Sentry::Metrics.count("pipeline.render.accepted", value: accepted, attributes: attributes)
    Sentry::Metrics.count("pipeline.render.rejected", value: rejected, attributes: attributes)
  end
end
