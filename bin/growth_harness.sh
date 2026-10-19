#!/bin/bash

# DEPRECATED 2026-09-20 -- DO NOT RE-ENABLE. The live publisher is
# bin/scheduled_posting.sh, driven hourly from the user crontab (`0 * * * *`).
#
# Why this file must stay dead: it runs the SAME `scheduling:post_scheduled` task
# on the SAME hourly cadence, so re-adding it to cron would put TWO drivers on the
# publisher -- the exact two-driver race the ops board warns about elsewhere (they
# interleave read-modify-write on shared state and double-release due posts). It
# also predates the burst fix: `scheduling:post_scheduled` now paces releases
# through Scheduling::PostReleasePlan (one post per tick), and it repairs
# placeholder captions, salvages abandoned renders and collects insights first --
# none of which this wrapper does, because it calls the bare rake task.
#
# Evidence it is dead: nothing in the repo or the crontab invokes it, and
# log/growth_harness.log has not been written since 2026-08-20 (it ends on the
# then-unfixed `TypeError: no implicit conversion of Hash into String` from the
# content_strategy initializer). Kept for history only; the openspec change
# add-growth-harness documents what it was meant to be.
#
# Turbo Carnival - Growth Harness (HISTORICAL)
# Single autonomous loop for the follower-growth pipeline, run on an hourly
# schedule:
#   1. growth:sync_cadence       - top up scheduled posts to meet cadence
#   2. scheduling:post_scheduled - publish any posts now due (was scheduled_posting.sh)
#   3. growth:snapshot_followers - capture follower count (API permitting)
#   4. growth:review_strategy    - strategy brain (respects review interval)
#
# Replaces bin/scheduled_posting.sh: it only posted due items, whereas this
# loop also keeps the queue full and measures/adjusts strategy. The review
# respects its own interval (default 7 days), so running hourly is safe.
# Set GROWTH_PERSONA=<name> to target a specific persona.

set -e

APP_DIR="/home/tim/source/activity/turbo-carnival"
LOG_FILE="$APP_DIR/log/growth_harness.log"
PERSONA="${GROWTH_PERSONA:-}"

mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "=========================================="
log "Starting growth harness run (persona: ${PERSONA:-default})"

if [ -s "$HOME/.rvm/scripts/rvm" ]; then
    source "$HOME/.rvm/scripts/rvm"
elif [ -s "/usr/share/rvm/scripts/rvm" ]; then
    source "/usr/share/rvm/scripts/rvm"
else
    log "ERROR: RVM not found"
    exit 1
fi

cd "$APP_DIR" || {
    log "ERROR: Cannot change to $APP_DIR"
    exit 1
}

rvm use 3.4.5 2>&1 | tee -a "$LOG_FILE"

ARGS=""
if [ -n "$PERSONA" ]; then
    ARGS="[$PERSONA]"
fi

log "Running cadence sync..."
bundle exec rails "growth:sync_cadence${ARGS}" 2>&1 | tee -a "$LOG_FILE" || log "ERROR: cadence sync failed"

log "Running scheduled posting..."
# NOTE: scheduling:post_scheduled posts ALL due posts and takes no persona arg
bundle exec rails "scheduling:post_scheduled" 2>&1 | tee -a "$LOG_FILE" || log "ERROR: scheduled posting failed"

log "Running follower snapshot..."
bundle exec rails "growth:snapshot_followers${ARGS}" 2>&1 | tee -a "$LOG_FILE" || log "ERROR: snapshot failed"

log "Running strategy review..."
bundle exec rails "growth:review_strategy${ARGS}" 2>&1 | tee -a "$LOG_FILE" || log "ERROR: review failed"

EXIT_CODE=${PIPESTATUS[0]}
log "Growth harness run completed (exit $EXIT_CODE)"
log "=========================================="

exit 0