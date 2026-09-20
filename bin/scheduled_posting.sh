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

bundle exec rails scheduling:post_scheduled 2>&1 | tee -a "$LOG_FILE"

EXIT_CODE=${PIPESTATUS[0]}

if [ $EXIT_CODE -eq 0 ]; then
    log "Completed successfully"
else
    log "ERROR: Task exited with code $EXIT_CODE"
fi

log "=========================================="

exit $EXIT_CODE
