# frozen_string_literal: true

# --- Sentry pillar (founders-harness minimum install) ---
# Ported from pi-216/rails-venture-template `template.rb` (PRD 0006 R7 · ticket #77).
#
# Provisioned 2026-10-19: project `turbo-carnival` on org `tim-lawrenz` (platform
# `ruby-rails`), DSN in `config/credentials/production.yml.enc` → `sentry_dsn`.
# Every Rails venture gets its own Sentry project by default (healthy default).
# DSN lives in encrypted Rails credentials, never env or the repo:
#   bin/rails credentials:edit → sentry_dsn: https://...@sentry.io/<id>
# Enabled only when a DSN is present, so dev/test stay silent by default.
#
# The org is on a Team plan — use the full surface, especially METRICS.
# Requires sentry-ruby >= 6.3.0; metrics are auto-enabled (no config flag).
# Emit pipeline/job outcomes, e.g.:
#   Sentry::Metrics.count("venture.<stage>.accepted", value: 1, attributes: { stage: "x" })
#   Sentry::Metrics.distribution("job.duration", ms, unit: "millisecond", attributes: { job: "X" })
if (dsn = Rails.application.credentials.sentry_dsn).present?
  Sentry.init do |config|
    config.dsn = dsn
    config.environment = ENV.fetch("SENTRY_ENVIRONMENT", Rails.env)
    config.release = ENV["SENTRY_RELEASE"].presence  # set git SHA on deploy
    # Silent in dev/test by default; add "development" if you run prod-grade locally.
    config.enabled_environments = %w[staging production]
    config.traces_sample_rate = 0.1  # bump toward 1.0 per maturity
  end
end
