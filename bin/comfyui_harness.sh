#!/bin/bash
# =============================================================================
# comfyui_harness.sh — scheduler-gated ComfyUI lifecycle for turbo-carnival.
#
# Tim's directive (2026-09-01): ComfyUI launch AND shutdown go through the
# file-based GPU scheduler. NEVER run ComfyUI without an active claim — an
# unclaimed ComfyUI makes the scheduler report "idle" while the GPU is 97%
# busy, which can double-book the 4090 to another agent.
#
# Usage:
#   bin/comfyui_harness.sh status
#       Print one line: claim=<idle|busy|claimed> job=<id|none> \
#       ours=<yes|no> comfyui=<up|down>
#       "ours" = the 4090's current job matches our state-file job id.
#   bin/comfyui_harness.sh ensure [--wait SECONDS]
#       Acquire a claim (request->poll->activate), launch ComfyUI detached,
#       start a 5-min heartbeat loop, wait until /system_stats answers.
#       Exit 0 with claim info on success; exit 2 if the GPU is unavailable
#       within --wait (default 300s) — caller should SKIP rendering this tick.
#       Self-heals: an orphaned ComfyUI (up, no claim, GPU idle) is shut down
#       before acquiring, so we never double-launch on port 8188.
#   bin/comfyui_harness.sh heartbeat
#       One explicit heartbeat (normally the background loop handles this).
#   bin/comfyui_harness.sh shutdown
#       Stop the heartbeat loop, SIGTERM ComfyUI, verify port closed + GPU
#       idle, then release the scheduler claim. Always leaves the GPU free.
# =============================================================================
set -u

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEDULER_PY=/mnt/nas-ai-models/gpu-scheduler/gpu_scheduler.py
SCHED="python3 $SCHEDULER_PY"
PY3="$(command -v python3)"
COMFY_MEM_MAX=24G        # memory ceiling for ComfyUI's OWN cgroup (see launch_comfyui)
GPU=4090
PROJECT=turbo-carnival
VRAM=21
DURATION=9h
COMFY_DIR=/mnt/fscache/essdee/ComfyUI
COMFY_VENV=.venv
COMFY_PORT=8188
STATE_FILE="$APP_DIR/log/comfyui_claim.json"
HARNESS_LOG="$APP_DIR/log/comfyui_harness.log"
HEARTBEAT_INTERVAL=300   # 5 min
UP_WAIT=240              # max seconds to wait for /system_stats after launch
POLL_INTERVAL=10

mkdir -p "$(dirname "$HARNESS_LOG")"

sched() { python3 "$SCHEDULER_PY" "$@"; }

# Transient systemd user unit names this harness owns. Both ComfyUI and the
# heartbeat loop run in their OWN cgroups so they survive the launching shell
# AND the Hermes cron worker's 4 GiB memory scope.
comfy_unit() { echo "comfyui-svc-${1#comfyui-}"; }
hb_unit()    { echo "comfyui-hb-${1#comfyui-}"; }
hb_alive()   { systemctl --user is-active "$(hb_unit "$1")" >/dev/null 2>&1; }
stop_heartbeat() {
  local job="$1"; [ -n "$job" ] || return 0
  systemctl --user stop "$(hb_unit "$job")" >/dev/null 2>&1 || true
}

# Remove a job WE created from the scheduler queue. release() alone returns
# "not_owner" while another agent holds the GPU, leaving a queued entry that
# would block the next agent's front-of-queue for up to 24h (expire window).
# Only ever called with job ids this script generated itself (comfyui-<ts>-<pid>).
cleanup_job() {
  local jid="$1"
  [ -n "$jid" ] || return 0
  sched release --gpu "$GPU" --job-id "$jid" --status failed >/dev/null 2>&1 || true
  rm -f "/mnt/nas-ai-models/gpu-scheduler/jobs/${jid}.json" 2>/dev/null || true
  log "cleanup: removed queued request $jid"
}

log() { echo "[$(date '+%F %T')] $*" | tee -a "$HARNESS_LOG"; }

comfyui_up() {
  [ "$(curl -s -m5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${COMFY_PORT}/system_stats" 2>/dev/null)" = "200" ]
}

# True when ComfyUI's native queue holds no work (no running, no pending
# prompt). Used by the orphan self-heal: an unclaimed instance with queued
# renders is producing real work and must NOT be SIGTERMed (queue-first
# directive 2026-09-07). Exit 0 = empty/idle, exit 1 = has work.
comfyui_queue_empty() {
  curl -s -m5 "http://127.0.0.1:${COMFY_PORT}/queue" 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)   # not parseable → treat as idle; the up/GPU checks gate killing
sys.exit(0 if not d.get("queue_running") and not d.get("queue_pending") else 1)
'
}

# True when the running ComfyUI is one WE launched — its pid is recorded as
# comfy_pid in our state file. Ownership rule: never kill what we did not
# spawn. If the state file is missing (tmpfs wipe) we conservatively treat it
# as foreign and leave it alone.
comfyui_ours() {
  local want pid
  want="$(read_state | sed -n '3p')"
  [ -n "$want" ] || return 1
  pid="$(pgrep -f 'main\.py --listen' 2>/dev/null | head -1)"
  [ -n "$pid" ] && [ "$pid" = "$want" ]
}

# Discover the running ComfyUI's pid and record it in the state file as ours.
record_comfy_pid() {
  local job="$1" cp
  cp="$(pgrep -f 'main\.py --listen' 2>/dev/null | head -1)"
  if [ -n "$cp" ]; then
    write_state "$job" "$(read_state | sed -n '2p')" "$cp"
    log "comfy pid $cp recorded for $job"
  fi
}

gpu_idle() {
  # No current_job on the 4090 (reads shared NAS state).
  sched status --gpu "$GPU" 2>/dev/null | grep -q 'current_job: None'
}

vram_mib() { nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' '; }

read_state() {
  # echo job_id, heartbeat_pid, comfy_pid from state file (empty strings if absent)
  python3 - "$STATE_FILE" <<'PY'
import json, sys, os
p = sys.argv[1]
if os.path.exists(p):
    try:
        d = json.load(open(p))
        print(d.get("job_id", ""))
        print(d.get("heartbeat_pid", ""))
        print(d.get("comfy_pid", ""))
        sys.exit(0)
    except Exception:
        pass
print("")
print("")
print("")
PY
}

write_state() {
  # args: job_id heartbeat_pid [comfy_pid]
  python3 - "$STATE_FILE" "$1" "$2" "${3:-}" <<'PY'
import json, sys
json.dump({"job_id": sys.argv[2], "heartbeat_pid": sys.argv[3], "comfy_pid": sys.argv[4]}, open(sys.argv[1], "w"))
PY
}

kill_comfyui() {
  local pids
  pids="$(pgrep -f 'main\.py --listen' 2>/dev/null)"
  if [ -z "$pids" ]; then
    log "ComfyUI: no main.py process running"
    return 0
  fi
  log "ComfyUI: SIGTERM to PIDs: $pids"
  kill -TERM $pids 2>/dev/null
  local waited=0
  while kill -0 $(echo "$pids" | head -1) 2>/dev/null && [ "$waited" -lt 30 ]; do
    sleep 2; waited=$((waited + 2))
  done
  if kill -0 $(echo "$pids" | head -1) 2>/dev/null; then
    log "ComfyUI: still alive after TERM, SIGKILL"
    kill -KILL $pids 2>/dev/null
    sleep 3
  fi
  log "ComfyUI: down (port check: $(comfyui_up && echo 'STILL UP' || echo 'closed'))"
}

cmd_status() {
  local sline jobline
  sline="$(sched status --gpu "$GPU" 2>/dev/null)"
  local status current_job
  status="$(echo "$sline" | sed -n 's/^  status: *//p' | tr -d ' ')"
  current_job="$(echo "$sline" | sed -n 's/^  current_job: *//p' | tr -d ' ')"
  [ -z "$status" ] && status="unknown"
  { [ -z "$current_job" ] || [ "$current_job" = "None" ]; } && current_job=""

  local job_id hb_pid
  job_id="$(read_state | head -1)"
  hb_pid="$(read_state | sed -n '2p')"

  local ours=no
  if [ -n "$current_job" ] && [ "$current_job" != "None" ] && [ "$current_job" = "$job_id" ]; then
    ours=yes
  fi
  # Claim can be active but state file lost (e.g. tmpfs wipes): if the GPU is
  # claimed and our heartbeat UNIT is still active, treat the claim as ours.
  if [ "$ours" = "no" ] && [ -n "${job_id:-}" ] && hb_alive "$job_id"; then
    ours=yes
  fi

  local cu=down
  comfyui_up && cu=up
  echo "claim=$status job=${current_job:-none} ours=$ours comfyui=$cu"
}

cmd_ensure() {
  local wait_s=300
  while [ $# -gt 0 ]; do
    case "$1" in
      --wait) wait_s="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  local job_id hb_pid sline status current_job
  job_id="$(read_state | head -1)"
  hb_pid="$(read_state | sed -n '2p')"

  if [ -n "$job_id" ]; then
    sline="$(sched status --gpu "$GPU" 2>/dev/null)"
    current_job="$(echo "$sline" | sed -n 's/^  current_job: *//p' | tr -d ' ')"
    status="$(echo "$sline" | sed -n 's/^  status: *//p' | tr -d ' ')"

    if [ "$current_job" = "$job_id" ] && [ "$status" != "idle" ]; then
      # We already hold the claim. (Re)start the heartbeat unit if it died.
      if ! hb_alive "$job_id"; then
        start_heartbeat_loop "$job_id"
      fi
      if comfyui_up; then
        log "ensure: claim $job_id already active, ComfyUI up"
        echo "job_id=$job_id"
        return 0
      fi
      log "ensure: claim $job_id active but ComfyUI down — relaunching"
      launch_comfyui "$job_id"
      echo "job_id=$job_id"
      return 0
    fi
    # Stale state-file job (never claimed / expired): clean it so it can't
    # sit queued and block the next agent, then acquire fresh below.
    if [ -n "$job_id" ]; then
      cleanup_job "$job_id"
      rm -f "$STATE_FILE"
    fi
  fi

  # Orphan self-heal: ComfyUI up but NO claim on an idle GPU == our leak.
  # Ownership rule (Tim correction 2026-09-07): only kill instances WE
  # launched (comfy_pid in our state file). A foreign unclaimed ComfyUI is
  # never ours to kill — adopt it under our claim instead. And even for our
  # own orphan, never SIGTERM while its native queue holds renders (running or
  # pending): queued work is live work, killing it is counterproductive.
  if comfyui_up && gpu_idle; then
    if comfyui_ours; then
      if comfyui_queue_empty; then
        log "ensure: our orphaned ComfyUI idle with no claim — shutting down before acquiring"
        kill_comfyui
        local waited=0
        while comfyui_up && [ "$waited" -lt 60 ]; do sleep 2; waited=$((waited + 2)); done
      else
        log "ensure: our orphaned ComfyUI has queued renders — NOT shutting down (queue-first); acquiring claim to adopt it"
      fi
    else
      log "ensure: unclaimed ComfyUI NOT launched by us (foreign) — leaving it untouched; acquiring claim to adopt it"
    fi
  fi

  # GPU held by another agent (or we never had a job): acquire fresh.
  local job="comfyui-$(date +%s)-$$"
  log "ensure: requesting claim $job (vram ${VRAM}GB, duration ${DURATION})"
  sched request --gpu "$GPU" --project "$PROJECT" --vram "$VRAM" --duration "$DURATION" --job-id "$job" >/dev/null 2>&1 || { log "ensure: request failed"; return 2; }

  local waited=0 result
  while [ "$waited" -lt "$wait_s" ]; do
    result="$(sched poll --gpu "$GPU" --job-id "$job" 2>/dev/null | tr -d '[:space:]')"
    if [ "$result" = "claimed" ]; then
      log "ensure: CLAIMED $job (after ${waited}s)"
      sched activate --gpu "$GPU" --job-id "$job" --progress-unit render >/dev/null 2>&1 || true
      local hb
      start_heartbeat_loop "$job"
      hb="$(read_state | sed -n '2p')"
      write_state "$job" "$hb"
      launch_comfyui "$job"
      echo "job_id=$job"
      return 0
    fi
    sleep "$POLL_INTERVAL"
    waited=$((waited + POLL_INTERVAL))
  done

  log "ensure: NOT claimed within ${wait_s}s (last result: ${result:-unknown}) — GPU unavailable, skipping this tick"
  cleanup_job "$job"
  return 2
}

start_heartbeat_loop() {
  local job="$1" unit pid
  unit="$(hb_unit "$job")"
  # The loop MUST outlive the cron execution that starts it. A plain `( ... ) &`
  # subshell dies with its owner (executions.db status='unknown'), the heartbeat
  # goes stale, and the claim is reaped after 30 min with no `release` — which
  # orphans the job FILE at the FIFO head and starves every project behind it.
  # Run it as its own systemd user unit so the claim lives as long as ComfyUI does.
  systemctl --user stop "$unit" >/dev/null 2>&1 || true
  systemctl --user reset-failed "$unit" >/dev/null 2>&1 || true
  systemd-run --user --unit="$unit" --collect \
    bash -c "while true; do $PY3 $SCHEDULER_PY heartbeat --gpu $GPU --job-id $job --progress 1 --vram-used $VRAM >>$HARNESS_LOG 2>&1; sleep $HEARTBEAT_INTERVAL; done" >/dev/null 2>&1
  pid="$(systemctl --user show -p MainPID --value "$unit" 2>/dev/null)"
  case "$pid" in ''|0) pid="" ;; esac
  write_state "$job" "$pid"
  log "heartbeat unit ${unit} started (MainPID ${pid:-?}) for $job — every ${HEARTBEAT_INTERVAL}s"
}

launch_comfyui() {
  local job="$1"
  # Adopt-or-launch: if a ComfyUI is already answering on the port (foreign
  # or adopted orphan), recording its pid makes it "ours" — never spawn a
  # second instance that would fail to bind (queue-first adoption, 2026-09-07).
  if comfyui_up; then
    log "launch_comfyui: ComfyUI already answering — adopting existing instance for $job"
    record_comfy_pid "$job"
    return 0
  fi

  local slog="/mnt/nas-ai-models/gpu-scheduler/logs/comfyui-${job}.log"
  local unit; unit="$(comfy_unit "$job")"
  # Launch in ComfyUI's OWN transient cgroup. A plain `setsid nohup` escapes the
  # session but NOT the cgroup: when this harness runs from a Hermes cron tick,
  # ComfyUI inherits that worker's scope (memory.max = 4 GiB) and the kernel OOM
  # killer SIGKILLs it ~25 s into model load (Flux weights ≈ 3.9 GB anon RSS) —
  # every tick, mid-render, with only a leaked-semaphore warning in the log.
  # systemd-run --user gives it a dedicated unit with a real ceiling.
  systemctl --user stop "$unit" >/dev/null 2>&1 || true
  systemctl --user reset-failed "$unit" >/dev/null 2>&1 || true
  log "launching ComfyUI (${COMFY_DIR}) in unit ${unit} (MemoryMax=${COMFY_MEM_MAX}) — log: ${slog}"
  systemd-run --user --unit="$unit" --collect \
    --property MemoryMax="${COMFY_MEM_MAX}" --property MemoryAccounting=yes \
    --property StandardOutput=append:"$slog" --property StandardError=append:"$slog" \
    --working-directory "$COMFY_DIR" \
    "$COMFY_DIR/${COMFY_VENV}/bin/python" main.py --listen 0.0.0.0 --enable-manager --fp32-text-enc >/dev/null 2>&1 \
    || log "WARNING: systemd-run failed to start unit ${unit}"

  local waited=0
  while ! comfyui_up && [ "$waited" -lt "$UP_WAIT" ]; do
    sleep 5; waited=$((waited + 5))
  done
  if comfyui_up; then
    log "ComfyUI up after ${waited}s"
  else
    log "WARNING: ComfyUI did not answer /system_stats within ${UP_WAIT}s — tail ${slog}"
    tail -5 "$slog" 2>/dev/null | tee -a "$HARNESS_LOG"
  fi
  record_comfy_pid "$job"
}

cmd_heartbeat() {
  local job_id
  job_id="$(read_state | head -1)"
  if [ -n "$job_id" ]; then
    sched heartbeat --gpu "$GPU" --job-id "$job_id" --progress 1 --vram-used "$VRAM" 2>&1 | tee -a "$HARNESS_LOG"
  else
    log "heartbeat: no active claim in state file"
    return 2
  fi
}

cmd_shutdown() {
  local job_id hb_pid
  job_id="$(read_state | head -1)"
  hb_pid="$(read_state | sed -n '2p')"

  # Queue-first guard (2026-09-07): never SIGTERM a ComfyUI whose native
  # queue still holds renders (running or pending). Killing live queued work
  # is counterproductive — refuse and keep the claim so work drains.
  if comfyui_up && ! comfyui_queue_empty; then
    log "shutdown: REFUSED — ComfyUI queue still has renders (running/pending); keeping claim $job_id alive so they drain"
    return 3
  fi

  if [ -n "$job_id" ]; then
    if hb_alive "$job_id"; then
      log "shutdown: stopping heartbeat unit $(hb_unit "$job_id")"
    fi
    stop_heartbeat "$job_id"
  fi

  kill_comfyui
  [ -n "$job_id" ] && systemctl --user stop "$(comfy_unit "$job_id")" >/dev/null 2>&1 || true

  if [ -n "$job_id" ]; then
    log "shutdown: releasing claim $job_id"
    sched release --gpu "$GPU" --job-id "$job_id" --status completed 2>&1 | tee -a "$HARNESS_LOG" || true
  else
    log "shutdown: no claim in state file (nothing to release)"
  fi

  rm -f "$STATE_FILE"

  local vm
  vm="$(vram_mib)"
  if comfyui_up; then
    log "shutdown: WARNING port ${COMFY_PORT} still answering"
  elif gpu_idle; then
    log "shutdown: clean — port closed, GPU idle (VRAM ${vm} MiB)"
  else
    log "shutdown: port closed but GPU NOT idle (VRAM ${vm} MiB) — check scheduler"
  fi
}

case "${1:-}" in
  status)   cmd_status ;;
  ensure)   shift; cmd_ensure "$@" ;;
  heartbeat) cmd_heartbeat ;;
  shutdown) cmd_shutdown ;;
  *)
    echo "usage: $0 {status|ensure [--wait SECONDS]|heartbeat|shutdown}" >&2
    exit 1 ;;
esac