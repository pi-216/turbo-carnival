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

# Fill hashtags on queued posts that have none (2026-09-20). The hashtag chain
# was repaired on 2026-09-19 (engine, persona strategy, the generator's create,
# the caption at send time) but every one of those fixes is on the PRODUCER
# side, so a row already in the queue keeps its empty column and the publisher
# appends nothing: measured 2026-09-20, post 340 (slot 09-24 17:50Z) was created
# two minutes AFTER the fix by a process still running pre-fix code, and the
# post would have shipped untagged. Same shape as the caption repair above --
# the publisher is the only path that knows the post is about to become public.
# Deliberately NON-FATAL -- an untagged post is still publishable, and the ops
# board keeps the condition open (check_queued_post_hashtags) so a repair that
# stops working cannot hide.
log "Filling hashtags on untagged queued posts (if any)..."
APPLY=1 INCLUDE_DUE=1 bundle exec rails hashtags:backfill_queued 2>&1 | tee -a "$LOG_FILE"
HASHTAG_CODE=${PIPESTATUS[0]}
if [ "$HASHTAG_CODE" -ne 0 ]; then
    log "WARN: hashtag backfill exited $HASHTAG_CODE — publishing anyway"
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

# Spend the render LIBRARY when the fresh-render path cannot keep the queue above
# its runway (2026-09-23). Growth::RenderSalvage above recovers renders that were
# already made; NOTHING here could help when no render happens at all -- and that
# is the recurring shape: the harness refuses to submit to a :8188 ComfyUI launched
# without --reserve-vram (the measured over-commit OOM), so another project's
# supervisor or the operator's own session blocks rendering for hours (1.5-96h
# holds, recurring since 2026-08-16) while the queue drains at ~3/day toward
# publishing SILENCE. The library (photos rendered and never posted) is the only
# content source that needs no GPU. The task is GPU-FREE, re-runs BOTH gates
# fail-closed on every photo, and is bounded twice over: it only acts under the
# SAME 72h runway threshold the ops board escalates on, and it tops up to 96h
# (<=3 posts/call), so a single hold cannot drain it. Measured depth 2026-09-23:
# of 51 servable unposted photos only 8 are spendable (15 NSFW-classified; all 28
# of the older May batch are soft -- sharpness 6.7-16.1 vs the 30.0 floor), so this
# buys ~2.7 days at 3/day, NOT weeks. It also cannot feed Growth::GateRead's cohort
# (that needs renders after 2026-09-21T23:35Z; every spendable library photo
# predates it) -- runway only.
# Deliberately NON-FATAL (same pattern as the steps above) — a fallback failure must
# never stall publishing.
log "Restoring publish runway from the render library (if short)..."
APPLY=1 bundle exec rails growth:library_fallback 2>&1 | tee -a "$LOG_FILE"
LIBRARY_CODE=${PIPESTATUS[0]}
if [ "$LIBRARY_CODE" -ne 0 ]; then
    log "WARN: library fallback exited $LIBRARY_CODE — publishing anyway"
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

# Re-book the slot of a post Instagram rejected (2026-09-21). `failed` is terminal in
# the state machine, the (photo_id, persona_id) index is UNIQUE so no replacement row
# can be created, and nothing else in the pipeline ever reads a `failed` row -- so a
# rejected post lost BOTH its slot and its paid-for render while the publisher exited
# 0 (3 lifetime occurrences: posts 37, 246, 333; the newest 2026-09-20 15:15Z, a 9007
# readiness race that survived the 4x/10s publish retry). Scheduling::FailedPostRetry
# re-books the row onto a PostSlotPlanner slot, but ONLY for causes it classifies as
# transient and only ONCE per row -- a policy rejection stays failed and stays on the
# ops board for a human. Runs ahead of the publisher so a re-booked slot can be
# released on the very tick it is due. Deliberately NON-FATAL (same pattern as the
# repairs above): a recovery failure must never stall publishing.
log "Re-booking posts Instagram rejected transiently (if any)..."
APPLY=1 LIMIT=3 bundle exec rails scheduling:retry_failed 2>&1 | tee -a "$LOG_FILE"
RETRY_CODE=${PIPESTATUS[0]}
if [ "$RETRY_CODE" -ne 0 ]; then
    log "WARN: failed-post retry exited $RETRY_CODE — publishing anyway"
fi

log "Checking queued renders for a juvenile apparent-age read (persona age gate)..."

# Hold any queued post whose render reads as a minor (2026-09-21). The account is
# adult-oriented and NOTHING between a render and Instagram asked how old the
# person in the image looks: independent vision reads of production renders
# returned "a young girl, likely a teenager" / "late teens or early twenties"
# repeatedly, and the newest read ("early teens to early twenties") was on a
# render the pipeline had already QUEUED. Every existing gate measures something
# else -- the NSFW gate scored those images 0.0004-0.0722 (comfortably safe), the
# realism gate measures artifice, and the prompt-safety repair (c016653) fixed
# the stored workflow's INPUT with no check on the OUTPUT. The publisher is the
# only path that knows a post is about to become public, so the gate lives here,
# ahead of scheduling:post_scheduled. GPU-FREE: the read is a vision call on the
# caption host (~15s per render). Bounded to LIMIT posts per tick, nearest slot
# first, and each post is read once (the verdict is recorded on the row).
# Deliberately NON-FATAL, and it FAILS OPEN: a caption-service outage leaves
# every post publishing exactly as before (the gate records nothing and retries
# next tick), so it can never stall the queue. A hold clears the post's two
# publisher clocks, which reopens the cadence shortfall so the next growth tick
# renders a replacement.
log "Running persona age gate on queued renders..."
APPLY=1 LIMIT=2 bundle exec rails growth:age_gate[Sarah] 2>&1 | tee -a "$LOG_FILE"
AGE_GATE_CODE=${PIPESTATUS[0]}
if [ "$AGE_GATE_CODE" -ne 0 ]; then
    log "WARN: age gate exited $AGE_GATE_CODE — publishing anyway"
fi

# Hold any queued post whose render duplicates an image already published, or
# already queued to publish (2026-09-24). Instagram removed 36 of the 150 posts
# this account published, and the removals are CONTENT-linked: posts 138-142
# published the SAME image on five consecutive days (dHash distance 0, one
# collapsed render directory) and all five were removed, every pair at distance
# <= 6 in the corpus is inside the removed set, and no surviving pair is closer
# than 7. Nothing in the repo checked for this (grep for dhash/phash/perceptual
# over packs/ bin/ app/ lib/ found nothing), so the only thing standing between a
# collapsed render batch and a duplicate post was nothing. Instagram suppresses
# duplicate content, so this is a removal cause AND an independent candidate
# contributor to the account's ~0 reach.
#
# The publisher is the only path that knows a post is about to become public, so
# the gate lives here, ahead of scheduling:post_scheduled -- alongside the age
# gate and for the same reason. GPU-FREE (dHash over the assets via bin/dhash.py;
# Ruby has no PNG decoder in this bundle) and bounded to LIMIT posts per tick,
# nearest slot first. Of a collapsed batch, exactly one member survives (the
# earliest slot) and the rest are held; a hold clears the post's two publisher
# clocks, which reopens the cadence shortfall so the next growth tick renders a
# replacement.
#
# Deliberately NON-FATAL, and it FAILS OPEN: a missing/undecodable asset or an
# unavailable hasher records nothing and publishes exactly as before, so the gate
# can never stall the queue.
log "Checking queued renders for near-duplicates..."
APPLY=1 LIMIT=3 bundle exec rails growth:near_dup_gate[Sarah] 2>&1 | tee -a "$LOG_FILE"
NEAR_DUP_CODE=${PIPESTATUS[0]}
if [ "$NEAR_DUP_CODE" -ne 0 ]; then
    log "WARN: near-duplicate gate exited $NEAR_DUP_CODE — publishing anyway"
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
