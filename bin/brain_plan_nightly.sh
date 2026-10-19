#!/bin/bash
# =============================================================================
# brain_plan_nightly.sh — the nightly planner window (PRD 0001, ticket #64).
#
# Founder ruling, 2026-10-19: THE PLANNER RUNS ONCE A NIGHT. The brain is ~22.3 GiB
# of a 24 GiB card and cannot be resident at tick time, so it owns the 4090 for this
# one bounded window. `ensure` takes the GPU claim and starts the seat, `brain:plan`
# plans and persists, then the harness stops the seat and RELEASES the card — the
# brain is never left resident, so the hourly cadence loop never contends with it.
#
# Install (user crontab), once a night:
#   0 3 * * * /home/tim/source/activity/turbo-carnival/bin/brain_plan_nightly.sh
#
# NOT installed by this repo: adding a crontab line is the operator's call.
# =============================================================================
# NOTE: deliberately NO `set -u` — RVM's rvm/scripts/support dereferences an unset
# `_system_name`, so `source rvm` aborts under `set -u` in a non-interactive shell.

APP_DIR="/home/tim/source/activity/turbo-carnival"
LOG_FILE="$APP_DIR/log/brain_plan_nightly.log"
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

# 1. Take the claim and start the seat. A refusal (vram_insufficient / busy) is a
#    NORMAL outcome — the card is shared — so the night is skipped, not failed.
if ! bin/brain_harness.sh ensure --wait 300; then
  log "ensure could not hold the card — skipping the planner this night (normal on a shared card)"
  exit 0
fi

# 2. Plan + persist. Never fatal: the log is the audit trail, cron stays green.
bundle exec rails brain:plan 2>&1 | tee -a "$LOG_FILE" || log "WARN: brain:plan returned nonzero"

# 3. Stop the seat and release the card, always — even if the plan step failed.
bin/brain_harness.sh shutdown 2>&1 | tee -a "$LOG_FILE" || log "WARN: harness stop returned nonzero"
exit 0
