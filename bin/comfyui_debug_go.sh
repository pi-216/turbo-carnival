#!/bin/bash
# =============================================================================
# comfyui_debug_go.sh — claim the 4090 for an INTERACTIVE ComfyUI debug session.
#
# Why this exists (2026-09-19): the automated renderer is the growth harness's
# hourly `comfyui_harness.sh ensure`. To hold the FIFO head for a human debug
# session we adopt the turbo-carnival entry already sitting at the front of the
# 4090 queue, claim it ourselves, and only then hand off to the harness (which
# does the heartbeat unit + instrumented launch — no launch logic is duplicated
# here). Since 2026-09-20 `ensure` adopts that same entry too
# (reconcile_own_queue) instead of minting a fresh id per tick, so the automated
# and the interactive path now agree on which queue entry is ours.
#
# Safe by default: if the GPU is still held by another project, it polls until
# --wait and then exits 0 WITHOUT side effects — the queued entry is left
# untouched so the automated loop can still use it later.
#
# Usage:
#   bin/comfyui_debug_go.sh [--wait SECONDS] [--job-id ID] [--dry-run]
# =============================================================================
set -u

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEDULER_PY=/mnt/nas-ai-models/gpu-scheduler/gpu_scheduler.py
GPU=4090
PROJECT=turbo-carnival
STATE_FILE="$APP_DIR/log/comfyui_claim.json"

WAIT=900          # seconds to keep polling for the slot (default 15 min)
JOB_ID=""
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --wait)    WAIT="$2"; shift 2 ;;
    --job-id)  JOB_ID="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) echo "usage: $0 [--wait SECONDS] [--job-id ID] [--dry-run]" >&2; exit 1 ;;
  esac
done

sched() { python3 "$SCHEDULER_PY" "$@"; }

log() { echo "[$(date '+%F %T')] $*"; }

# The FIFO head for our project, read from the DERIVED queue (job files), never
# from state.json's vestigial per-GPU `queue` field which always reads [].
discover_head() {
  python3 - "$SCHEDULER_PY" "$GPU" "$PROJECT" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("gs", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
q = [j for j in m.read_queue(sys.argv[2]) if j.get("project") == sys.argv[3]]
q.sort(key=lambda j: j.get("requested_at") or "")
print(q[0]["id"] if q else "")
PY
}

[ -n "$JOB_ID" ] || JOB_ID="$(discover_head)"
if [ -z "$JOB_ID" ]; then
  log "no queued $PROJECT entry on the $GPU — nothing to adopt."
  log "ask the automated loop for a fresh request, or submit one with:"
  log "  python3 $SCHEDULER_PY request --gpu $GPU --project $PROJECT --vram 21 --duration 9 --job-id <id>"
  exit 1
fi

log "adopting queued entry: $JOB_ID"
log "current 4090 state: $(sched status --gpu "$GPU" 2>/dev/null | sed -n 's/^  status: *//p;s/^  current_job: *//p' | tr '\n' ' ')"

if [ "$DRY" = "1" ]; then
  log "dry-run: would poll -> activate -> write state file -> ensure (nothing done)"
  exit 0
fi

# ---- poll until the scheduler grants the lease (or we time out) -------------
waited=0
result=""
while [ "$waited" -lt "$WAIT" ]; do
  result="$(sched poll --gpu "$GPU" --job-id "$JOB_ID" 2>/dev/null | tr -d '[:space:]')"
  if [ "$result" = "claimed" ]; then
    log "CLAIMED $JOB_ID after ${waited}s"
    break
  fi
  [ "$waited" = "0" ] && log "waiting for the slot (last result: ${result:-unknown})"
  sleep 20
  waited=$((waited + 20))
done

if [ "$result" != "claimed" ]; then
  log "NOT granted within ${WAIT}s (last result: ${result:-unknown}) — no side effects, entry kept for the automated loop."
  exit 0
fi

# ---- lease is ours: activate, publish the claim, hand off to the harness ----
sched activate --gpu "$GPU" --job-id "$JOB_ID" --progress-unit render >/dev/null 2>&1 || true
if ! python3 - "$STATE_FILE" "$JOB_ID" <<'PY'
import json, sys
json.dump({"job_id": sys.argv[2], "heartbeat_pid": "", "comfy_pid": ""}, open(sys.argv[1], "w"))
PY
then
  log "ERROR: could not write $STATE_FILE — releasing the lease"
  sched release --gpu "$GPU" --job-id "$JOB_ID" --status failed >/dev/null 2>&1 || true
  exit 1
fi
log "state file published; handing off to comfyui_harness.sh ensure"

if "$APP_DIR/bin/comfyui_harness.sh" ensure --wait 120; then
  log "ComfyUI up under claim $JOB_ID — debug away."
  log "telemetry: bin/comfyui_harness.sh telemetry 20"
else
  log "ERROR: harness ensure failed after we took the lease — releasing so the queue is not blocked"
  "$APP_DIR/bin/comfyui_harness.sh" shutdown >/dev/null 2>&1 || true
  sched release --gpu "$GPU" --job-id "$JOB_ID" --status failed >/dev/null 2>&1 || true
  rm -f "$STATE_FILE"
  exit 1
fi