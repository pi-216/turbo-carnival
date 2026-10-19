#!/bin/bash
# Cron wrapper for the brain check-in (ticket #24, W1.1). A silently-dead brain
# must be an ALERT, not a discovery — see packs/growth_harness/lib/tasks/brain.rake.
#
# Install (user crontab), every 15 minutes:
#   */15 * * * * /home/tim/source/activity/turbo-carnival/bin/brain_checkin.sh
set -u

APP_DIR="/home/tim/source/activity/turbo-carnival"
LOG_FILE="$APP_DIR/log/brain_checkin.log"
mkdir -p "$(dirname "$LOG_FILE")"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }

if [ -s "$HOME/.rvm/scripts/rvm" ]; then
  # shellcheck disable=SC1091
  source "$HOME/.rvm/scripts/rvm"
elif [ -s "/usr/share/rvm/scripts/rvm" ]; then
  # shellcheck disable=SC1091
  source "/usr/share/rvm/scripts/rvm"
else
  log "ERROR: RVM not found"; exit 1
fi

cd "$APP_DIR" || { log "ERROR: cannot cd $APP_DIR"; exit 1; }
rvm use 3.4.5 >/dev/null 2>&1 || true

# The check-in itself must never take the cron slot down; a nonzero rake exit is
# logged but not fatal to the wrapper.
bundle exec rails brain:checkin 2>&1 | tee -a "$LOG_FILE" || log "WARN: brain:checkin returned nonzero"
exit 0
