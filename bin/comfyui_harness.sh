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
SCHED_DIR=/mnt/nas-ai-models/gpu-scheduler
# The scheduler's queue is DERIVED from jobs/*.json (state.json's per-GPU `queue`
# field is vestigial and reads [] even while jobs wait). Overridable so the
# reconciliation logic can be exercised against a fixture directory without
# touching the live queue.
SCHED_JOBS_DIR="${TC_SCHED_JOBS_DIR:-$SCHED_DIR/jobs}"
PY3="$(command -v python3)"
# NO artificial memory cap on ComfyUI (Tim, 2026-09-19): "if you have the GPU,
# there is no one else in the blast radius — that's what the scheduler is for."
# The GPU claim already guarantees exclusivity, so a MemoryMax protects nothing
# and actively harms: ComfyUI reports ram_total = its cgroup limit and sizes its
# RAM cache / offload budget from that number, so the cap both starved offload
# and made ComfyUI believe the machine was small. Measured progression:
#   24G -> cgroup OOM mid model-load (anon-rss 23.7 GiB)
#   48G -> VRAM OOM at node SamplerCustomAdvanced (offload starved, swap full)
#   96G -> render succeeds; genuine working set peaks at 69.3 GiB
# "infinity" keeps MemoryAccounting on, so the telemetry sampler can still read
# memory.current/peak/events, but nothing kills ComfyUI for using RAM.
COMFY_MEM_MAX=infinity
GPU=4090
PROJECT=turbo-carnival
VRAM=21
DURATION=9h
COMFY_DIR=/mnt/fscache/essdee/ComfyUI
COMFY_VENV=.venv
COMFY_PORT=8188
STATE_FILE="$APP_DIR/log/comfyui_claim.json"
HARNESS_LOG="${TC_HARNESS_LOG:-$APP_DIR/log/comfyui_harness.log}"
HARNESS_LOG_MAX_LINES=1200   # rotate past this (probe flags >1500)
HARNESS_LOG_KEEP_LINES=600   # retention window kept after rotation
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
  rm -f "${SCHED_JOBS_DIR}/${jid}.json" 2>/dev/null || true
  log "cleanup: removed queued request $jid"
}

# Our own queued (never-granted) entries on this GPU, oldest first.
own_queued_jobs() {
  python3 - "$SCHED_JOBS_DIR" "$GPU" "$PROJECT" <<'PY'
import json, os, sys
jobs_dir, gpu, project = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    names = os.listdir(jobs_dir)
except FileNotFoundError:
    names = []
rows = []
for n in names:
    if not n.endswith(".json"):
        continue
    try:
        d = json.load(open(os.path.join(jobs_dir, n)))
    except Exception:
        continue
    if d.get("status") == "queued" and d.get("gpu") == gpu and d.get("project") == project:
        rows.append((d.get("requested_at", ""), d.get("id", n[:-5])))
rows.sort()
for _, jid in rows:
    print(jid)
PY
}

# Reconcile our own queue entries and echo the one to ADOPT (empty if none).
#
# Root cause this closes (measured 2026-09-20): `poll` refuses with
# `not_my_turn` whenever ANY queued entry has requested_at <= ours, so a queued
# entry nobody polls blocks its own project AND every project behind it until
# the 24h expire window -- and if the co-tenant releases meanwhile the card sits
# physically idle. This harness leaked exactly such entries: it mints a fresh
# comfyui-<ts>-<pid> per tick, and when the tick was SIGKILLed mid-wait (the
# caller's tool budget is 180s, the default wait 300s) cleanup_job never ran, so
# the entry stayed queued; the next tick then requested ANOTHER id behind its own
# leaked predecessor and read `not_my_turn` -- from itself (live: 19:01Z and
# 21:00Z entries leaked, 20:04Z refusal caused by our own 19:01Z entry).
# Adopt the OLDEST own entry (best FIFO position) and cancel newer duplicates, so
# at most ONE outstanding request exists per project.
reconcile_own_queue() {
  local own=() jid
  mapfile -t own < <(own_queued_jobs)
  if [ "${#own[@]}" -eq 0 ]; then
    echo ""
    return 0
  fi
  for jid in "${own[@]:1}"; do
    log "reconcile: cancelling duplicate queued request $jid (one outstanding request per project)"
    cleanup_job "$jid"
  done
  echo "${own[0]}"
}

log() {
  rotate_harness_log
  echo "[$(date '+%F %T')] $*" | tee -a "$HARNESS_LOG"
}

# Retention window for the harness log: this file is append-only and nothing else
# prunes it, so it grew unbounded (1999 lines / 172 KB by 2026-09-19) and the ops
# board flagged it. Keep the tail (enough to reconstruct the last few launches) and
# drop the rest, noting the rotation in-line so the truncation is never mysterious.
rotate_harness_log() {
  [ -f "$HARNESS_LOG" ] || return 0
  local n
  n=$(wc -l < "$HARNESS_LOG" 2>/dev/null || echo 0)
  [ "${n:-0}" -gt "$HARNESS_LOG_MAX_LINES" ] || return 0
  tail -n "$HARNESS_LOG_KEEP_LINES" "$HARNESS_LOG" > "$HARNESS_LOG.rot.tmp" 2>/dev/null || { rm -f "$HARNESS_LOG.rot.tmp"; return 0; }
  mv -f "$HARNESS_LOG.rot.tmp" "$HARNESS_LOG" || return 0
  echo "[$(date '+%F %T')] harness log rotated: was $n lines, kept last $HARNESS_LOG_KEEP_LINES" >> "$HARNESS_LOG"
}

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

# Who is actually serving port 8188: ours (pid recorded in our state file) or a
# foreign instance started outside this harness (a byobu/tmux shell, another
# agent). WHY: `comfyui=up` on its own cannot be attributed, so a co-tenant's
# instance and our own orphan look identical -- and the watchdog prompt calls any
# up-instance-while-ours=no an "orphaned leak", which is wrong while another
# project holds the claim and runs the shared install (observed 2026-09-19
# 20:15: pid 2585253, cgroup tmux-spawn-*.scope, 386 MiB, prx-tg held the claim).
# pid + cgroup + start time are the discriminators; the tokens are appended so
# the existing `claim=/job=/ours=/comfyui=` parse is untouched.
comfyui_attribution() {
  local pid cg started who=foreign
  pid="$(pgrep -f 'main\.py --listen' 2>/dev/null | head -1)"
  [ -n "$pid" ] || { echo "owner=unknown"; return 0; }
  comfyui_ours && who=ours
  cg="$(sed -n 's/^0:://p' "/proc/$pid/cgroup" 2>/dev/null)"
  started="$(ps -o lstart= -p "$pid" 2>/dev/null | xargs)"
  echo "owner=$who pid=$pid cgroup=${cg:-?} started=${started// /_}"
}

# Discover the running ComfyUI's pid and record it in the state file as ours.
# This is also the instrumentation hook: every path that ends with a live
# ComfyUI (fresh launch AND adoption of an orphan) passes through here, so the
# cgroup assertion and the telemetry sampler always start.
record_comfy_pid() {
  local job="$1" cp
  cp="$(pgrep -f 'main\.py --listen' 2>/dev/null | head -1)"
  if [ -n "$cp" ]; then
    write_state "$job" "$(read_state | sed -n '2p')" "$cp"
    log "comfy pid $cp recorded for $job"
    instrument_comfyui "$job" "$cp"
  fi
}

# ---------------------------------------------------------------------------
# Launch instrumentation (added 2026-09-19)
#
# Why: on 2026-09-18 ComfyUI was SIGKILLed by the kernel cgroup OOM killer ~22 s
# after launch, on EVERY hourly tick, because it had inherited the Hermes cron
# worker scope (memory.max = 4 GiB) instead of escaping into its own unit.
# Neither the harness log nor ComfyUI's own log said so — the only evidence was
# in `journalctl -k` ("Killed process 335708 (python) anon-rss:3989872kB",
# oom_memcg=.../hermes-worker-cron-43b0d5c4446d-exec-*.scope) and it aged out.
# Two additions close that gap:
#   1. assert the launched pid's cgroup is a comfyui-svc-* unit — fail loudly
#   2. sample that cgroup's memory + oom_kill counters from a SURVIVING unit
# ---------------------------------------------------------------------------
TELE_SCRIPT="$APP_DIR/script/comfyui_telemetry.py"
TELE_FILE="$APP_DIR/log/comfyui_telemetry.jsonl"
TELE_OUT="$APP_DIR/log/comfyui_telemetry.out"
TELE_INTERVAL=30         # seconds between cgroup/VRAM samples

tele_unit() { echo "comfyui-tele-${1#comfyui-}"; }

pid_cgroup_of() { [ -n "${1:-}" ] && cat "/proc/$1/cgroup" 2>/dev/null | cut -d: -f3; }

instrument_comfyui() {
  local job="$1" cp="$2" cg
  cg="$(pid_cgroup_of "$cp")"
  log "instrument: comfy pid $cp cgroup=${cg:-unknown}"
  case "$cg" in
    *comfyui-svc-*)
      log "instrument: OK — launch is in its own unit cgroup, not the cron scope" ;;
    *hermes-worker-cron*)
      log "instrument: ERROR — comfy pid $cp is INSIDE a hermes cron worker cgroup (${cg}); the 4 GiB cap will OOM-kill it. Fix the launch path before spending the claim." ;;
    *)
      log "instrument: WARN — unexpected cgroup for comfy pid $cp: ${cg:-unknown}" ;;
  esac
  start_telemetry "$job" "$cp"
}

start_telemetry() {
  local job="$1" cp="$2" unit
  if [ ! -f "$TELE_SCRIPT" ]; then
    log "instrument: telemetry script missing ($TELE_SCRIPT) — skipping sampler"
    return 0
  fi
  unit="$(tele_unit "$job")"
  systemctl --user stop "$unit" >/dev/null 2>&1 || true
  systemctl --user reset-failed "$unit" >/dev/null 2>&1 || true
  # Its own unit => it survives the death it is watching; a sampler inside the
  # cron scope would be OOM-killed alongside ComfyUI and record nothing.
  systemd-run --user --unit="$unit" --collect \
    --property StandardOutput=append:"$TELE_OUT" \
    --property StandardError=append:"$TELE_OUT" \
    "$PY3" "$TELE_SCRIPT" --pid "$cp" --job "$job" \
    --out "$TELE_FILE" --interval "$TELE_INTERVAL" >/dev/null 2>&1 \
    || log "instrument: WARN telemetry unit $unit failed to start"
  log "instrument: telemetry unit ${unit} watching pid $cp every ${TELE_INTERVAL}s → $TELE_FILE"
}

telemetry_report() {
  # Log the last telemetry record for a job, plus the AUTHORITATIVE kernel
  # attribution. A --collect'd transient unit takes its cgroup counters with it
  # the moment it is collected, so the sampler can miss the final oom_kill
  # increment; the kernel journal is the reliable record, and the OOM line names
  # our own unit in oom_memcg=, so grep by unit name.
  local job="$1" last unit jl
  unit="comfyui-svc-${1#comfyui-}"
  if [ -f "$TELE_FILE" ]; then
    last="$(grep -F "\"job\": \"${job}\"" "$TELE_FILE" 2>/dev/null | tail -1)"
    [ -n "$last" ] || last="$(tail -1 "$TELE_FILE" 2>/dev/null)"
    log "instrument: last telemetry: ${last:-none}"
    case "$last" in
      *'"oom_kill_events": 0'*|*'"oom_kill_events": null'*|"") : ;;
      *'"oom_kill_events"'*) log "instrument: OOM KILL recorded by the watcher — see $TELE_FILE" ;;
    esac
  else
    log "instrument: no telemetry file for ${job:-?}"
  fi
  jl="$(journalctl -k --since '-30 min' --no-pager 2>/dev/null | grep -F "$unit" | grep -i -E 'oom-kill|Killed process' | tail -2)"
  if [ -n "$jl" ]; then
    log "instrument: KERNEL OOM ATTRIBUTION (unit $unit): $jl"
    log "instrument: unit MemoryMax is ${COMFY_MEM_MAX} — if the OOM is attributed to this unit, raise COMFY_MEM_MAX before relaunching."
  fi
}

cmd_telemetry() {
  local n="${1:-10}"
  if [ ! -f "$TELE_FILE" ]; then echo "no telemetry at $TELE_FILE"; return 1; fi
  echo "== last ${n} telemetry records ($TELE_FILE) =="
  tail -n "$n" "$TELE_FILE"
}

gpu_idle() {
  # No current_job on the 4090 (reads shared NAS state).
  sched status --gpu "$GPU" 2>/dev/null | grep -q 'current_job: None'
}

vram_mib() { nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' '; }

vram_free_mib() { nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' '; }

# WHO is holding the card when our request is refused. A bare `vram_insufficient`
# forces every consumer of the log -- the growth brain's report, the ops probe, a
# human -- to re-derive the cause from scratch (measured 2026-09-20: the refusal
# was a co-tenant's BreastTissue-Net process holding 4.6 GiB outside the
# scheduler, diagnosed by hand twice). Name the holder once, where it happens.
vram_holders() {
  local out
  out="$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null \
        | paste -sd'; ' -)"
  if [ -n "$out" ]; then echo "$out"; else echo "no compute process"; fi
}

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

  local cu=down owner=""
  if comfyui_up; then
    cu=up
    owner=" $(comfyui_attribution)"
  fi
  echo "claim=$status job=${current_job:-none} ours=$ours comfyui=$cu$owner"
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
      telemetry_report "$job_id"
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

  # GPU held by another agent (or we never had a job): adopt our own queued
  # entry if we have one (it holds the best FIFO position), else request fresh.
  local job="" attempts=0 result=""
  while [ "$attempts" -lt 2 ]; do
    attempts=$((attempts + 1))
    job="$(reconcile_own_queue)"
    if [ -z "$job" ]; then
      job="comfyui-$(date +%s)-$$"
      log "ensure: requesting claim $job (vram ${VRAM}GB, duration ${DURATION})"
      sched request --gpu "$GPU" --project "$PROJECT" --vram "$VRAM" --duration "$DURATION" --job-id "$job" >/dev/null 2>&1 || { log "ensure: request failed"; return 2; }
    else
      log "ensure: adopting our own queued entry $job (keeps the best FIFO position)"
      # A granted record keeps status "queued", so a claim that is already OURS
      # with the state file lost (tmpfs wipe) is recoverable here instead of
      # being re-requested behind ourselves.
      local sl cj st
      sl="$(sched status --gpu "$GPU" 2>/dev/null)"
      cj="$(echo "$sl" | sed -n 's/^  current_job: *//p' | tr -d ' ')"
      st="$(echo "$sl" | sed -n 's/^  status: *//p' | tr -d ' ')"
      if [ "$cj" = "$job" ] && [ "$st" != "idle" ]; then
        log "ensure: entry $job is already GRANTED to us (state file lost) — recovering the claim"
        if ! hb_alive "$job"; then start_heartbeat_loop "$job"; fi
        write_state "$job" "$(read_state | sed -n '2p')"
        launch_comfyui "$job"
        echo "job_id=$job"
        return 0
      fi
    fi

    result=""
    local waited=0
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
      # not_my_turn cannot resolve inside this tick: poll only claims when NO
      # queued entry is at or ahead of ours, so waiting just burns the caller's
      # budget -- and when the caller is killed mid-wait the entry is leaked,
      # which is the failure this block exists to prevent.
      if [ "$result" = "not_my_turn" ]; then
        log "ensure: NOT claimed — $job is behind another queued job (not_my_turn after ${waited}s); entry stays queued for the next tick"
        return 2
      fi
      sleep "$POLL_INTERVAL"
      waited=$((waited + POLL_INTERVAL))
    done

    if [ "$result" = "not_queued" ]; then
      log "ensure: $job is no longer queued (expired or released under us) — re-requesting once"
      continue
    fi
    break
  done

  log "ensure: NOT claimed within ${wait_s}s (last result: ${result:-unknown}) — GPU unavailable, skipping this tick"
  if [ "${result:-}" = "vram_insufficient" ]; then
    log "ensure: why — free=$(vram_free_mib)MiB vs requested ${VRAM}GiB; holders: $(vram_holders)"
    log "ensure: note — the ${VRAM}GiB reservation is MEASURED (ComfyUI peaks ~23.2GiB on this card), so a co-tenant holding >3GiB outside the scheduler starves renders; do not lower it to fit"
  fi
  # Keep the entry ONLY while we are waiting our turn behind an earlier queued
  # job: that is normal FIFO waiting and deleting it would only lose our place
  # (and re-mint a fresh id behind ourselves next tick -- the flood). When we are
  # at the HEAD and still cannot take the card (idle but short of VRAM, a
  # co-tenant holding memory outside the scheduler, thermal, unhealthy), holding
  # the head would block SMALLER jobs behind us that could run, so give the place
  # up and let the next tick re-request.
  if [ "${result:-}" != "not_my_turn" ]; then
    cleanup_job "$job"
    log "ensure: gave up the FIFO head (last result: ${result:-unknown}) so a job behind us can take the card"
  else
    log "ensure: keeping queued entry ${job:-none} for the next tick (waiting our turn behind another job)"
  fi
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

# ---------------------------------------------------------------------------
# Self-healing venv provisioning (Tim, 2026-09-19: "if the hourly/nightly
# monitoring jobs report problems, fix them" — so build the fix into the launch).
# A `git pull` that bumps a pinned dependency is invisible until the next launch,
# which then dies with ModuleNotFoundError. Observed: requirements.txt pinned
# comfy-aimdo==0.5.5 while the venv had 0.5.3, which has no storage.py ->
# "No module named 'comfy_aimdo.storage'"; `import comfy.storage` fails and
# ComfyUI cannot start at all. The known-good manual launch includes the pip
# step — this makes the harness do it, but ONLY when the venv is actually
# inconsistent, so the healthy path stays fast.
# ---------------------------------------------------------------------------
ensure_comfyui_deps() {
  local py="$COMFY_DIR/${COMFY_VENV}/bin/python"
  local pip="$COMFY_DIR/${COMFY_VENV}/bin/pip"
  [ -x "$py" ] && [ -x "$pip" ] || return 0
  "$py" -c 'import comfy.storage' >/dev/null 2>&1 && return 0
  log "deps: ComfyUI runtime import FAILED — provisioning venv (pip install)"
  local f
  for f in requirements.txt manager_requirements.txt; do
    [ -f "$COMFY_DIR/$f" ] || continue
    ( cd "$COMFY_DIR" && "$pip" install -r "$f" ) >>"$HARNESS_LOG" 2>&1 || \
      log "deps: WARN pip install -r $f returned nonzero"
  done
  if "$py" -c 'import comfy.storage' >/dev/null 2>&1; then
    log "deps: venv provisioned OK — runtime import now succeeds"
  else
    log "deps: ERROR — import still failing after pip install; launch will likely fail"
  fi
}

launch_comfyui() {
  local job="$1"
  ensure_comfyui_deps
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
  # EXACT known-good launch (Tim, 2026-09-19): this is the invocation that
  # produced images dependably for this persona. Do NOT add flags to it. Removed
  # from the previous version: --fp32-text-enc (doubles the text-encoder RAM and
  # VRAM — logged as "CLIP/text encoder ... dtype: float32" — a major part of the
  # observed 69 GiB working set) and --enable-manager (registry network fetches at
  # every startup). The venv is pre-provisioned with requirements.txt +
  # manager_requirements.txt, so no pip step belongs in the launch path.
  log "launching ComfyUI (${COMFY_DIR}) in unit ${unit} (MemoryMax=${COMFY_MEM_MAX}) — log: ${slog}"
  systemd-run --user --unit="$unit" --collect \
    --property MemoryMax="${COMFY_MEM_MAX}" --property MemoryAccounting=yes \
    --property StandardOutput=append:"$slog" --property StandardError=append:"$slog" \
    --working-directory "$COMFY_DIR" \
    "$COMFY_DIR/${COMFY_VENV}/bin/python" main.py --listen 0.0.0.0 >/dev/null 2>&1 \
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
  status)    cmd_status ;;
  ensure)    shift; cmd_ensure "$@" ;;
  heartbeat) cmd_heartbeat ;;
  telemetry) shift; cmd_telemetry "$@" ;;
  shutdown)  cmd_shutdown ;;
  ownqueue)  own_queued_jobs ;;
  reconcile) reconcile_own_queue ;;
  *)
    echo "usage: $0 {status|ensure [--wait SECONDS]|heartbeat|telemetry [N]|shutdown|ownqueue|reconcile}" >&2
    exit 1 ;;
esac