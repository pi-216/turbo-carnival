#!/bin/bash

# Turbo Carnival - Scheduled Posting Script
# This script ensures the correct Ruby version is used via RVM

set -e

APP_DIR="/home/tim/source/activity/turbo-carnival"
LOG_FILE="/home/tim/source/activity/turbo-carnival/log/scheduled_posting.log"

mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "=========================================="
log "Starting scheduled post check"

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

rvm use 3.4.1 2>&1 | tee -a "$LOG_FILE"

RUBY_VERSION=$(ruby -v)
log "Using Ruby: $RUBY_VERSION"

log "Running scheduled post task..."
# Repair placeholder captions BEFORE publishing (2026-09-20). Both growth
# producers write the literal 'Fresh look ✨' when the captioner fails, and the
# post is then queued like any other -- so a caption outage publishes its own
# failure artifact. Nothing re-tried it, and the repair
# (captions:refresh_placeholders) was opt-in, so the placeholder stayed in the
# queue until a human ran APPLY=1. The publisher is the right place to fix it: it
# is the only path that knows the post is about to become public.
# Deliberately NON-FATAL -- if the captioner is down the placeholder publishes
# exactly as before, and the ops board keeps the condition open
# (check_placeholder_caption_queued), so a repair failure cannot stall publishing.
log "Repairing queued placeholder captions (if any)..."
APPLY=1 INCLUDE_DUE=1 bundle exec rails captions:refresh_placeholders 2>&1 | tee -a "$LOG_FILE"
REPAIR_CODE=${PIPESTATUS[0]}
if [ "$REPAIR_CODE" -ne 0 ]; then
    log "WARN: placeholder caption repair exited $REPAIR_CODE — publishing anyway"
fi

# Recover PAID-FOR renders that no post was ever made from (2026-09-20). The
# growth tick's recovery path lives inside CadenceEngine#sync, and the tick skips
# the whole cadence step when it cannot acquire the 4090 -- so the one recovery
# path that needs no GPU at all was gated behind the GPU, and abandoned renders
# sat on disk for 13h+ while a foreign claim held the card and the queue drained.
# This runs hourly, GPU-free, bounded by the cadence shortfall and idempotent
# (a Photo row is the marker), so it can only ever finish work already paid for.
# Deliberately NON-FATAL -- a recovery failure must never stall publishing.
log "Recovering abandoned renders (GPU-free)..."
bundle exec rails growth:salvage_abandoned 2>&1 | tee -a "$LOG_FILE"
SALVAGE_CODE=${PIPESTATUS[0]}
if [ "$SALVAGE_CODE" -ne 0 ]; then
    log "WARN: render salvage exited $SALVAGE_CODE — publishing anyway"
fi

# Collect engagement insights for posted items (2026-09-20). The insights columns
# are what Growth::WeeklyReview aggregates per pillar to steer hashtags/content,
# and the command that fills them existed since May -- but nothing invoked it (no
# rake task, no cron), so the newest write was 2026-05-27 and 107 posted items had
# no insights at all: every pillar's engagement read 0.0. The publisher is the only
# in-repo hook that runs on a schedule regardless of the GPU gate. Deliberately
# NON-FATAL (same pattern as the steps above): an Instagram API failure must never
# stall publishing, and a sustained failure stays visible on the ops board
# (bin/tc_ops.py check_insights_stale -> `insights-stale`).
log "Collecting engagement insights for posted items..."
bundle exec rails scheduling:collect_insights 2>&1 | tee -a "$LOG_FILE"
INSIGHTS_CODE=${PIPESTATUS[0]}
if [ "$INSIGHTS_CODE" -ne 0 ]; then
    log "WARN: insights collection exited $INSIGHTS_CODE — publishing anyway"
fi

bundle exec rails scheduling:post_scheduled 2>&1 | tee -a "$LOG_FILE"

EXIT_CODE=${PIPESTATUS[0]}

if [ $EXIT_CODE -eq 0 ]; then
    log "Completed successfully"
else
    log "ERROR: Task exited with code $EXIT_CODE"
fi

log "=========================================="

exit $EXIT_CODE
