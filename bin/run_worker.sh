#!/usr/bin/env bash
# Turbo Carnival Sidekiq launcher (growth harness worker).
#
# WHY THIS EXISTS (2026-09-19): Procfile.dev declared a `worker:` line but the
# systemd unit only ran the web server, so no Sidekiq process ever ran for this
# app. JobPollerWorker -- the only thing that advances ComfyuiJob and
# PipelineRun to a terminal status -- therefore never ran: no ComfyuiJob has
# been marked `completed` since 2026-05-26 and no PipelineRun since 2026-05-28,
# while 241 jobs accumulated in `submitted` and 379 runs in `pending`. The render
# path still produced images (ContentGenerator polls ComfyUI directly), which is
# why the pipeline looked alive while its bookkeeping silently rotted.
#
# Mirrors bin/run_server.sh: systemd user services run with a minimal env, so
# pin rvm's Ruby 3.4.5 explicitly.
set -euo pipefail

export PATH="/usr/share/rvm/gems/ruby-3.4.5/bin:/usr/share/rvm/gems/ruby-3.4.5@global/bin:/usr/share/rvm/rubies/ruby-3.4.5/bin:$PATH"
export GEM_HOME="/usr/share/rvm/gems/ruby-3.4.5"
export GEM_PATH="/usr/share/rvm/gems/ruby-3.4.5:/usr/share/rvm/gems/ruby-3.4.5@global"

export RAILS_ENV=development

cd /home/tim/source/activity/turbo-carnival
exec "$(command -v bundle 2>/dev/null || echo /usr/share/rvm/gems/ruby-3.4.5/bin/bundle)" \
  exec sidekiq -C config/sidekiq.yml