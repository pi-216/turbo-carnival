#!/usr/bin/env bash
# Turbo Carnival Rails server launcher (growth harness host, port 3004).
# systemd user services run with a minimal env; pin the rvm Ruby 3.4.5 like
# crawlr's run_production.sh does.
set -euo pipefail

export PATH="/usr/share/rvm/gems/ruby-3.4.5/bin:/usr/share/rvm/gems/ruby-3.4.5@global/bin:/usr/share/rvm/rubies/ruby-3.4.5/bin:$PATH"
export GEM_HOME="/usr/share/rvm/gems/ruby-3.4.5"
export GEM_PATH="/usr/share/rvm/gems/ruby-3.4.5:/usr/share/rvm/gems/ruby-3.4.5@global"

export RAILS_ENV=development
# This host runs the harness prod-grade under RAILS_ENV=development (see above), but the
# Sentry pillar is enabled only in a *configured* environment (`staging`/`production`, the
# template's minimum install). Without this the app would come up and drop everything it
# captured, which is how a venture ends up installing observability and still seeing
# nothing. SENTRY_ENVIRONMENT is the template's own escape hatch for exactly this case.
export SENTRY_ENVIRONMENT=production
export RAILS_SERVE_STATIC_FILES=1
export PORT=3004

cd /home/tim/source/activity/turbo-carnival
exec "$(command -v bundle 2>/dev/null || echo /usr/share/rvm/gems/ruby-3.4.5/bin/bundle)" exec rails server -p 3004 -b 0.0.0.0