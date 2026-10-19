#!/bin/bash
# =============================================================================
# brain_harness.sh — scheduler-gated local-reader (llama.cpp) lifecycle for
# turbo-carnival. The "brain" of PRD 0001: the local uncensored Qwen3.8-27B.
#
#   docs/prd/0001-local-uncensored-brain-and-phase-machine.md
#   docs/PROJECT_PLAN.md#w11-local-brain-and-phase-machine  (ticket #24, W1.1)
#
# Mirrors bin/comfyui_harness.sh on purpose: the brain gets the SAME claim
# discipline ComfyUI already has. NEVER start llama-server without a live
# scheduler claim — an unclaimed server makes the scheduler report "idle" while
# the 4090 is ~21 GiB busy, which can double-book the card to another agent.
#
# Usage:
#   bin/brain_harness.sh status
#       Print one line: claim=<idle|busy|claimed> job=<id|none> \
#       ours=<yes|no> brain=<up|down>
#       "ours" = the 4090's current job matches our state-file job id.
#   bin/brain_harness.sh ensure [--wait SECONDS]
#       Acquire a claim (request->poll->activate) and start llama-server
#       detached under it; start a 5-min heartbeat loop; wait until /health
#       answers. An already-answering server is ADOPTED, never doubled.
#       Exit 0 with job_id= on success; exit 2 if the GPU is unavailable
#       within --wait (default 300s) — the caller SKIPS the plan phase.
#   bin/brain_harness.sh heartbeat
#       One explicit scheduler heartbeat (the background loop does this too).
#   bin/brain_harness.sh shutdown
#       Stop the heartbeat loop, SIGTERM our server, verify the port is closed
#       and the GPU idle, then release the claim. Always leaves the card free.
#   bin/brain_harness.sh plan [FREE_MIB]
#       Offline: what ensure would ask for. No GPU, no claim.
#   bin/brain_harness.sh deps
#       Offline: is the llama-server binary + artefact present/readable?
# =============================================================================
set -u

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEDULER_PY="${TC_SCHEDULER_PY:-/mnt/nas-ai-models/gpu-scheduler/gpu_scheduler.py}"
SCHED_DIR=/mnt/nas-ai-models/gpu-scheduler
# Overridable so the FIFO/refusal logic can be exercised against a fixture.
SCHED_JOBS_DIR="${TC_SCHED_JOBS_DIR:-$SCHED_DIR/jobs}"
SCHED_STATE_JSON="${TC_SCHED_STATE:-$SCHED_DIR/state.json}"
SCHED_LOG_DIR="$SCHED_DIR/logs"

GPU=4090
PROJECT=turbo-carnival

# The seat's data (artefact path + serving params) lives as DATA, not a memory.
BRAIN_YML="${TC_BRAIN_YML:-$APP_DIR/config/autonomous/brain.yml}"
# ruby is the only YAML reader guaranteed here (python3 has no PyYAML on this box).
RUBY_BIN="$(command -v ruby || echo /usr/share/rvm/rubies/ruby-3.4.5/bin/ruby)"

# llama.cpp built for the 4090 (CUDA). See PRD 0001 "Model staging".
BRAIN_BIN="${TC_BRAIN_BIN:-/home/tim/source/activity/llama.cpp/build/bin/llama-server}"
BRAIN_HOST="${BRAIN_HOST:-127.0.0.1}"
BRAIN_PORT="${BRAIN_PORT:-8080}"

# The ask when the card is FREE. A FIT value, not the footprint: the artefact is
# 20.57 GiB, and llama.cpp adds KV cache + compute buffers on top. Budgeted
# against live free memory below. #26 replaces this with a MEASURED number.
BRAIN_VRAM="${BRAIN_VRAM:-22}"
BRAIN_MIN_FIT="${BRAIN_MIN_FIT:-18}"
FIT_HEADROOM_MIB="${FIT_HEADROOM_MIB:-1024}"
DURATION="${BRAIN_DURATION:-2h}"

STATE_FILE="${TC_BRAIN_CLAIM_FILE:-$APP_DIR/log/brain_claim.json}"
HARNESS_LOG="${TC_BRAIN_LOG:-$APP_DIR/log/brain_harness.log}"
HARNESS_LOG_MAX_LINES=1200
HARNESS_LOG_KEEP_LINES=600
HEARTBEAT_INTERVAL=300   # 5 min; the scheduler reaps a claim after 30 min stale
UP_WAIT=240              # max seconds to wait for /health after launch
POLL_INTERVAL="${TC_POLL_INTERVAL:-10}"
ENSURE_DEADLINE_S="${TC_ENSURE_DEADLINE:-360}"
PY3="$(command -v python3)"

mkdir -p "$(dirname "$HARNESS_LOG")"
mkdir -p "$(dirname "$STATE_FILE")"

sched() { python3 "$SCHEDULER_PY" "$@"; }

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$HARNESS_LOG" >&2; }

# --- state file: line1=job_id line2=heartbeat-unit-pid line3=server pid line4=origin
read_state()      { [ -f "$STATE_FILE" ] && sed -n '1,4p' "$STATE_FILE" || true; }
write_state()     { printf '%s\n%s\n%s\n%s\n' "${1:-}" "${2:-}" "${3:-}" "${4:-}" > "$STATE_FILE"; }

hb_unit()    { echo "brain-hb-${1#brain-}"; }
svc_unit()   { echo "brain-svc-${1#brain-}"; }
hb_alive()   { systemctl --user is-active "$(hb_unit "$1")" >/dev/null 2>&1; }

stop_heartbeat() {
  local job="$1" unit; unit="$(hb_unit "$job")"
  systemctl --user stop "$unit" >/dev/null 2>&1 || true
  systemctl --user reset-failed "$unit" >/dev/null 2>&1 || true
}

# --- the artefact + serving params, read from brain.yml (never hard-coded) -----
# One tiny YAML reader; the file is ours and flat, so this stays honest.
yml_get() {
  "$RUBY_BIN" -ryaml -rdate -e '
    v = (YAML.safe_load(File.read(ARGV[0]), permitted_classes: [Date, Time], aliases: true) rescue nil) || {}
    ARGV[1].split(".").each { |k| v = v.is_a?(Hash) ? v[k] : nil }
    print(v.nil? ? "" : v.to_s)
  ' "$BRAIN_YML" "$1" 2>/dev/null || true
}

brain_model() { yml_get artefact.path; }

# Serving defaults are #26's to REPLACE with measured values in brain.yml. Until
# then these are sane, KV-quantised defaults (a 20.57 GiB model on a 24 GiB card
# needs KV quantisation: q8_0 KV ≈ 32 KiB/token ⇒ 32K ctx ≈ 1 GiB).
brain_serve_args() {
  local model="$1"
  local ngl ctx ctk ctv bs ub
  ngl="$(yml_get serving.n_gpu_layers)"; ctx="$(yml_get serving.ctx_size)"
  ctk="$(yml_get serving.cache_type_k)"; ctv="$(yml_get serving.cache_type_v)"
  bs="$(yml_get serving.batch_size)";     ub="$(yml_get serving.ubatch_size)"
  echo --model "$model" \
       --host "$BRAIN_HOST" --port "$BRAIN_PORT" \
       --n-gpu-layers "${ngl:-999}" \
       --ctx-size "${ctx:-32768}" \
       --cache-type-k "${ctk:-q8_0}" --cache-type-v "${ctv:-q8_0}" \
       --batch-size "${bs:-2048}" --ubatch-size "${ub:-512}" \
       --flash-attn on --alias brain --no-warmup
}

# --- probes -------------------------------------------------------------------
brain_up() { curl -sf "http://${BRAIN_HOST}:${BRAIN_PORT}/health" >/dev/null 2>&1; }
brain_pid() { pgrep -f "${BRAIN_BIN}.*--port ${BRAIN_PORT}" 2>/dev/null | head -1; }
vram_mib()  { nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' '; }
vram_free_mib() { nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' '; }
gpu_idle()  { local u; u="$(vram_mib)"; [ -n "$u" ] && [ "$u" -lt 2048 ]; }

# Adaptive ask: never request more than the card can fit right now (a padded ask
# on a card with a desktop is a guaranteed vram_insufficient for the whole hour).
vram_ask_for_free() {
  local free_mib="$1" free_gb ask
  if [ -z "$free_mib" ]; then echo "$BRAIN_VRAM"; return; fi
  free_gb=$(( (free_mib - FIT_HEADROOM_MIB) / 1024 ))
  ask=$(( free_gb < BRAIN_MIN_FIT ? BRAIN_MIN_FIT : free_gb ))
  [ "$ask" -gt "$BRAIN_VRAM" ] && ask="$BRAIN_VRAM"
  [ "$ask" -lt 1 ] && ask="$BRAIN_MIN_FIT"
  echo "$ask"
}

sched_status_field() { sched status --gpu "$GPU" 2>/dev/null | sed -n "s/^  $1: *//p" | tr -d ' '; }

# ---------------------------------------------------------------------------
cmd_status() {
  local st job
  st="$(sched_status_field status)"; [ -z "$st" ] && st="unknown"
  job="$(sched_status_field current_job)"
  { [ -z "$job" ] || [ "$job" = "None" ]; } && job=""

  local state_job hb_pid ours=no
  state_job="$(read_state | head -1)"
  hb_pid="$(read_state | sed -n '2p')"
  if [ -n "$job" ] && [ "$job" = "$state_job" ]; then
    ours=yes
  elif [ -n "${state_job:-}" ] && hb_alive "$state_job"; then
    ours=yes   # claim active but state file lost (tmpfs wipe) — heartbeat still ours
  fi

  local bu=down; brain_up && bu=up
  echo "claim=$st job=${job:-none} ours=$ours brain=$bu"
}

# ---------------------------------------------------------------------------
cmd_ensure() {
  local wait_s=300
  while [ $# -gt 0 ]; do
    case "$1" in --wait) wait_s="$2"; shift 2 ;; *) shift ;; esac
  done

  local free_mib ask
  free_mib="$(vram_free_mib)"
  ask="$(vram_ask_for_free "$free_mib")"
  VRAM_ASK="$ask"
  [ "$ask" != "$BRAIN_VRAM" ] && log "ensure: adaptive fit — free=${free_mib}MiB < full ask ${BRAIN_VRAM}GiB, asking ${ask}GiB (headroom ${FIT_HEADROOM_MIB}MiB, floor ${BRAIN_MIN_FIT}GiB)"

  local job_id state_job hb_pid st cur
  job_id="$(read_state | head -1)"

  if [ -n "$job_id" ]; then
    st="$(sched_status_field status)"; cur="$(sched_status_field current_job)"
    if [ "$cur" = "$job_id" ] && [ "$st" != "idle" ]; then
      # We already hold the claim.
      hb_alive "$job_id" || start_heartbeat_loop "$job_id"
      if brain_up; then
        log "ensure: claim $job_id already active, brain up"
        echo "job_id=$job_id"; return 0
      fi
      log "ensure: claim $job_id active but brain down — relaunching"
      write_state "$job_id" "$(read_state | sed -n '2p')"
      launch_brain "$job_id"
      echo "job_id=$job_id"; return 0
    fi
    # Stale/expired entry — clean it so it can't sit queued and block others.
    cleanup_job "$job_id"
    rm -f "$STATE_FILE"
  fi

  # Adopt-or-launch: a brain already answering on the port is adopted under our
  # claim (never spawn a second llama-server that would fail to bind).
  if brain_up && [ -z "$job_id" ]; then
    log "ensure: brain already answering on ${BRAIN_HOST}:${BRAIN_PORT} with no claim — will acquire a claim to ADOPT it (we did not start it; shutdown must not stop it)"
  fi

  local job="" attempts=0 result=""
  while [ "$attempts" -lt 2 ]; do
    attempts=$((attempts + 1))
    if [ -z "$job" ]; then
      job="brain-$(date +%s)-$$-${attempts}"
      log "ensure: requesting claim $job (vram ${ask}GB, duration ${DURATION})"
      sched request --gpu "$GPU" --project "$PROJECT" --vram "$ask" --duration "$DURATION" --job-id "$job" >/dev/null 2>&1 \
        || { log "ensure: request failed"; return 2; }
    fi

    local waited=0
    while : ; do
      result="$(sched poll --gpu "$GPU" --job-id "$job" 2>/dev/null | tr -d '[:space:]')"
      if [ "$result" = "claimed" ]; then
        log "ensure: CLAIMED $job (after ${waited}s)"
        sched activate --gpu "$GPU" --job-id "$job" --progress-unit plan >/dev/null 2>&1 || true
        start_heartbeat_loop "$job"
        write_state "$job" "$(read_state | sed -n '2p')"
        launch_brain "$job"
        echo "job_id=$job"; return 0
      fi
      if [ "$result" = "not_my_turn" ]; then
        log "ensure: NOT claimed — $job is behind another queued/running job (blocker ahead); nobody guarantees release this tick, entry stays queued for the next tick. policy=brain_unclaimed"
        return 2
      fi
      if [ "$waited" -ge "$wait_s" ]; then break; fi
      sleep "$POLL_INTERVAL"; waited=$((waited + POLL_INTERVAL))
    done

    if [ "$result" = "not_queued" ]; then
      log "ensure: $job no longer queued (expired/released under us) — re-requesting once"
      continue
    fi
    break
  done

  log "ensure: NOT claimed within ${wait_s}s (last result: ${result:-unknown}) — GPU unavailable, skipping the plan phase. policy=brain_unclaimed"
  if [ "${result:-}" = "vram_insufficient" ]; then
    log "ensure: why — free=$(vram_free_mib)MiB vs requested ${ask}GiB. policy=brain_unclaimed"
  fi
  [ -n "$job" ] && cleanup_job "$job" "gave up the FIFO head (${result:-unknown}) so a job behind us can take the card"
  return 2
}

cleanup_job() {
  local job="$1" why="${2:-}"
  [ -n "$job" ] || return 0
  sched expire >/dev/null 2>&1 || true
  rm -f "$SCHED_JOBS_DIR/$job.json" 2>/dev/null || true
  [ -n "$why" ] && log "cleanup_job: retired $job ($why)"
}

# ---------------------------------------------------------------------------
start_heartbeat_loop() {
  local job="$1" unit pid
  unit="$(hb_unit "$job")"
  # MUST outlive the cron execution that starts it: a plain `( ) &` dies with its
  # owner, the heartbeat goes stale, the claim is reaped after 30 min with no
  # release, and the job FILE orphans at the FIFO head and starves everyone.
  systemctl --user stop "$unit" >/dev/null 2>&1 || true
  systemctl --user reset-failed "$unit" >/dev/null 2>&1 || true
  systemd-run --user --unit="$unit" --collect \
    bash -c "while true; do $PY3 $SCHEDULER_PY heartbeat --gpu $GPU --job-id $job --progress 1 --vram-used ${VRAM_ASK:-$BRAIN_VRAM} >>$HARNESS_LOG 2>&1; sleep $HEARTBEAT_INTERVAL; done" >/dev/null 2>&1
  pid="$(systemctl --user show -p MainPID --value "$unit" 2>/dev/null)"
  case "$pid" in ''|0) pid="" ;; esac
  write_state "$job" "$pid"
  log "heartbeat unit ${unit} started (MainPID ${pid:-?}) for $job — every ${HEARTBEAT_INTERVAL}s"
}

# ---------------------------------------------------------------------------
# NEVER called before a claim is active. This is the one invariant of the file.
launch_brain() {
  local job="$1"
  if brain_up; then
    log "launch_brain: brain already answering on ${BRAIN_HOST}:${BRAIN_PORT} — adopting existing instance for $job (origin=adopted: our claim covers it, we did not start it, so shutdown must NOT stop it)"
    record_brain_pid "$job" adopted; return 0
  fi

  local model; model="$(brain_model)"
  if [ -z "$model" ] || [ ! -r "$model" ]; then
    log "launch_brain: ERROR — artefact not readable: '${model:-<unset>}' (see $BRAIN_YML). Nothing launched."
    return 2
  fi
  if [ ! -x "$BRAIN_BIN" ]; then
    log "launch_brain: ERROR — llama-server not executable at $BRAIN_BIN"
    return 2
  fi

  local slog="$SCHED_LOG_DIR/brain-${job}.log"
  local unit; unit="$(svc_unit "$job")"
  # Own transient cgroup: a plain setsid/nohup inherits a Hermes cron worker's
  # scope and the kernel OOM-kills the loader mid-load (ComfyUI's lesson).
  systemctl --user stop "$unit" >/dev/null 2>&1 || true
  systemctl --user reset-failed "$unit" >/dev/null 2>&1 || true
  local args; args="$(brain_serve_args "$model")"
  log "launch_brain: unit ${unit}, artefact ${model}, args='${args}' — log: ${slog}"
  # shellcheck disable=SC2086
  systemd-run --user --unit="$unit" --collect \
    --property MemoryMax=infinity --property MemoryAccounting=yes \
    --property StandardOutput=append:"$slog" --property StandardError=append:"$slog" \
    "$BRAIN_BIN" $args >/dev/null 2>&1 \
    || log "WARNING: systemd-run failed to start unit ${unit}"

  local waited=0
  while ! brain_up && [ "$waited" -lt "$UP_WAIT" ]; do sleep 5; waited=$((waited + 5)); done
  if brain_up; then
    log "brain up after ${waited}s"
  else
    log "WARNING: brain did not answer /health within ${UP_WAIT}s — tail ${slog}"
    tail -5 "$slog" 2>/dev/null | tee -a "$HARNESS_LOG"
  fi
  record_brain_pid "$job"
}

record_brain_pid() {
  local job="$1" origin="${2:-launched}" pid
  pid="$(brain_pid)"
  local hb; hb="$(read_state | sed -n '2p')"
  write_state "$job" "$hb" "${pid:-}" "$origin"
}

# ---------------------------------------------------------------------------
cmd_heartbeat() {
  local job_id; job_id="$(read_state | head -1)"
  if [ -n "$job_id" ]; then
    sched heartbeat --gpu "$GPU" --job-id "$job_id" --progress 1 --vram-used "${VRAM_ASK:-$BRAIN_VRAM}" 2>&1 | tee -a "$HARNESS_LOG"
  else
    log "heartbeat: no active claim in state file"; return 2
  fi
}

# ---------------------------------------------------------------------------
cmd_shutdown() {
  local job_id hb_pid brain_pid origin
  job_id="$(read_state | head -1)"
  hb_pid="$(read_state | sed -n '2p')"
  brain_pid="$(read_state | sed -n '3p')"
  origin="$(read_state | sed -n '4p')"   # read BEFORE the state file is removed

  if [ -n "$job_id" ]; then
    hb_alive "$job_id" && log "shutdown: stopping heartbeat unit $(hb_unit "$job_id")"
    stop_heartbeat "$job_id"
  fi

  # Ownership rule: only stop a server WE launched (origin=launched). An adopted
  # instance belongs to whoever started it and is never ours to kill.
  if [ "$origin" = "launched" ] && [ -n "${brain_pid:-}" ]; then
    log "shutdown: SIGTERM our llama-server (pid ${brain_pid})"
    kill "$brain_pid" 2>/dev/null || true
    [ -n "$job_id" ] && systemctl --user stop "$(svc_unit "$job_id")" >/dev/null 2>&1 || true
  elif [ -n "${brain_pid:-}" ]; then
    log "shutdown: adopted instance (origin=${origin:-unrecorded}, pid ${brain_pid}) left running — not ours to stop"
  else
    log "shutdown: no server pid recorded — nothing of ours to stop"
  fi

  if [ -n "$job_id" ]; then
    log "shutdown: releasing claim $job_id"
    sched release --gpu "$GPU" --job-id "$job_id" --status completed 2>&1 | tee -a "$HARNESS_LOG" || true
  else
    log "shutdown: no claim in state file (nothing to release)"
  fi
  rm -f "$STATE_FILE"

  local waited=0 vm
  while brain_up && [ "$waited" -lt 60 ]; do sleep 2; waited=$((waited + 2)); done
  vm="$(vram_mib)"
  if brain_up; then
    log "shutdown: WARNING port ${BRAIN_PORT} still answering after stopping OUR instance"
  elif gpu_idle; then
    log "shutdown: clean — port ${BRAIN_PORT} closed, GPU idle (VRAM ${vm} MiB)"
  else
    log "shutdown: port closed but GPU NOT idle (VRAM ${vm} MiB) — check scheduler"
  fi
}

# ---------------------------------------------------------------------------
# Stop OUR server but KEEP the batch claim (claim + heartbeat untouched).
# This is what makes "one claim covers the whole batch" real (PRD 0001): the
# tenant server is swapped out INSIDE the claim, so the card is never yielded
# between phases and cannot be lost. Mirrors the kill path of cmd_shutdown,
# minus the release. Freeness is NOT asserted here -- CUDA holds VRAM briefly
# after the process exits, so the handoff takes the DEVICE reading afterwards.
cmd_stop_server() {
  local job_id hb_pid brain_pid origin
  job_id="$(read_state | head -1)"
  hb_pid="$(read_state | sed -n '2p')"
  brain_pid="$(read_state | sed -n '3p')"
  origin="$(read_state | sed -n '4p')"

  # Ownership: only a server WE launched (origin=launched) is ours to stop. An
  # adopted instance belongs to whoever started it and is never ours to kill.
  if [ "${origin:-}" = "launched" ] && [ -n "${brain_pid:-}" ]; then
    log "stop-server: SIGTERM our llama-server (pid ${brain_pid}); claim ${job_id:-none} RETAINED"
    kill "$brain_pid" 2>/dev/null || true
    [ -n "$job_id" ] && systemctl --user stop "$(svc_unit "$job_id")" >/dev/null 2>&1 || true
    # Clear the pid, keep job_id + heartbeat: the claim stays live for the render phase.
    printf '%s\n%s\n%s\n%s\n' "$job_id" "$hb_pid" "" "launched" > "$STATE_FILE"
  else
    log "stop-server: nothing of ours to stop (origin=${origin:-unrecorded}, pid=${brain_pid:-none}) — claim untouched"
  fi

  # Evidence is the PORT closing, never the kill's exit code.
  local waited=0
  while brain_up && [ "$waited" -lt 60 ]; do sleep 2; waited=$((waited + 2)); done
  if brain_up; then
    log "stop-server: WARNING port ${BRAIN_PORT} still answering after stopping OUR instance"
    return 1
  fi
  log "stop-server: port ${BRAIN_PORT} closed; claim ${job_id:-none} retained for the next phase"
  return 0
}

# ---------------------------------------------------------------------------
# Offline surfaces (no GPU, no claim) — same contract as comfyui_harness's.
cmd_plan() {
  local free_mib="${1:-}" ask model
  [ -n "$free_mib" ] || free_mib="$(vram_free_mib)"
  ask="$(vram_ask_for_free "$free_mib")"
  model="$(brain_model)"
  echo "free=${free_mib}MiB full_ask=${BRAIN_VRAM}GiB min_fit=${BRAIN_MIN_FIT}GiB headroom=${FIT_HEADROOM_MIB}MiB ask=${ask}GiB artefact=${model:-<unset>} serve_args=$(brain_serve_args "${model:-<unset>}")"
}

cmd_deps() {
  local model rc=0
  model="$(brain_model)"
  [ -x "$BRAIN_BIN" ] && echo "deps: llama-server OK — $BRAIN_BIN" || { echo "deps: FAILED — no executable at $BRAIN_BIN"; rc=2; }
  if [ -n "$model" ] && [ -r "$model" ]; then
    echo "deps: artefact OK — $model"
  else
    echo "deps: FAILED — artefact not readable: ${model:-<unset from $BRAIN_YML>}"; rc=2
  fi
  return "$rc"
}

case "${1:-}" in
  status)    cmd_status ;;
  ensure)    shift; cmd_ensure "$@" ;;
  heartbeat) cmd_heartbeat ;;
  shutdown)  cmd_shutdown ;;
  stop-server) cmd_stop_server ;;
  plan)      shift; cmd_plan "$@" ;;
  deps)      cmd_deps ;;
  *)
    echo "usage: $0 {status|ensure [--wait SECONDS]|heartbeat|shutdown|stop-server|plan [FREE_MIB]|deps}" >&2
    exit 1 ;;
esac
