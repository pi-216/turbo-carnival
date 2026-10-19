#!/bin/bash
# =============================================================================
# phase_handoff.sh — the measured free-VRAM gate between the 4090's two tenants.
#
# PRD   : docs/prd/0001-local-uncensored-brain-and-phase-machine.md
# Plan  : docs/PROJECT_PLAN.md#w11-local-brain-and-phase-machine  (ticket #25)
#
# The brain (llama.cpp, ~22 GiB) and ComfyUI (~23 GiB) cannot be co-resident on a
# 24 GiB card. This gate sequences them: it stops the outgoing tenant, then reads
# free VRAM FROM THE DEVICE and admits the incoming phase only when that measured
# reading clears the incoming tenant's floor.
#
# THE INVARIANT (PRD 0001 red line): CUDA holds VRAM briefly after a process
# exits, so a process exit code is NOT evidence that memory was freed — and on a
# shared card neither is "the pid is gone". The ONLY freeness signal this script
# consumes is a live `nvidia-smi memory.free` reading. The outgoing tenant's state
# is read from its own harness `status` (the port answering), never from a kill's
# return code.
#
# ONE CLAIM COVERS THE WHOLE BATCH (PRD 0001 Director story): this script does
# NOT take or release the GPU claim. It runs while a batch claim is held and
# swaps tenant servers INSIDE that claim, via each harness's `stop-server` — which
# stops the server but keeps the claim and heartbeat alive. Yielding the card
# between phases is exactly what the gate exists to prevent.
#
# A REFUSED BATCH IS A NORMAL OUTCOME, not an error: exit 3 means "park, do not
# start the incoming phase" (vram_insufficient | tenant_resident).
#
# Usage:
#   bin/phase_handoff.sh measure [--floor GIB]
#       Read free VRAM from the device and print the reading + verdict.
#       Exit 0 proceed, 3 park:vram_insufficient, 4 device unreadable.
#   bin/phase_handoff.sh check render|brain [--floor GIB]
#       Read-only admission: the verdict for entering the given phase right now,
#       using the DEVICE reading plus the OUTGOING tenant's state. Starts and
#       stops nothing. This is what a render/review request consults.
#   bin/phase_handoff.sh to-render [--floor GIB] [--wait SEC]
#       THINK -> RENDER transition. Stop the brain (ours only; claim retained),
#       then poll the DEVICE until measured free >= floor. Exit 0 = the render
#       phase may start; 3 = park (brain still resident, or free below floor);
#       4 = device unreadable. Never starts ComfyUI itself — the caller does,
#       under the same claim.
#   bin/phase_handoff.sh to-brain [--floor GIB] [--wait SEC]
#       RENDER -> JUDGE transition. Mirror of to-render: stop ComfyUI, then poll
#       the device; the review phase may start only on measured free VRAM.
#   bin/phase_handoff.sh plan FREE_MIB FLOOR_GIB [TENANT_STATE]
#       PURE, offline: what the gate would decide. No GPU, no claim, no I/O.
#       TENANT_STATE is up|down (default down). This is the testable core.
#   bin/phase_handoff.sh status
#       One line: brain=<up|down|unknown> comfyui=<up|down|unknown> \
#       free=<MiB|unreadable> floor=<GiB> verdict=<proceed|park:...>
# =============================================================================
set -u

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The two tenant harnesses are the single owners of claim/tenant lifecycle; this
# gate only reads their `status` and calls their claim-preserving `stop-server`.
BRAIN_HARNESS="${TC_BRAIN_HARNESS:-$APP_DIR/bin/brain_harness.sh}"
COMFYUI_HARNESS="${TC_COMFYUI_HARNESS:-$APP_DIR/bin/comfyui_harness.sh}"

# Default floors (GiB) — the incoming tenant's own minimum fit. Overridable.
PHASE_RENDER_FLOOR="${TC_RENDER_FLOOR:-16}"   # ComfyUI's VRAM_MIN_FIT
PHASE_BRAIN_FLOOR="${TC_BRAIN_FLOOR:-18}"     # brain's BRAIN_MIN_FIT
POLL_INTERVAL="${TC_HANDOFF_POLL:-5}"
DEFAULT_WAIT="${TC_HANDOFF_WAIT:-120}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] phase_handoff: $1" >&2; }

# --- THE INSTRUMENT: free VRAM, read from the device --------------------------
# Returns MiB on stdout, or nothing if the device cannot be read. There is
# deliberately NO fallback to "the process exited, so memory is free".
vram_free_mib() {
  nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null \
    | head -1 | tr -d '[:space:]'
}

# --- THE PURE DECISION (offline, no GPU, no claim) ----------------------------
# args: free_mib floor_gib tenant_state(up|down)
# prints: proceed | park:tenant_resident | park:vram_insufficient | park:vram_unreadable
# rc:     0 proceed, 3 park, 4 unreadable
#
# Order matters: residency is checked FIRST. If the outgoing tenant is still on
# the card, the incoming phase must not start even if the reading happens to
# clear the floor (a foreign tenant's partial reading is not ours to spend).
handoff_verdict() {
  local free_mib="${1:-}" floor_gib="${2:-}" tenant="${3:-down}"
  if [ "$tenant" != "down" ]; then
    echo "park:tenant_resident"; return 3
  fi
  case "$free_mib" in
    ''|*[!0-9]*) echo "park:vram_unreadable"; return 4 ;;
  esac
  if [ -z "$floor_gib" ] || [ "$free_mib" -lt $(( floor_gib * 1024 )) ]; then
    echo "park:vram_insufficient"; return 3
  fi
  echo "proceed"; return 0
}

# --- tenant state, read from the harness that owns it -------------------------
# brain|comfyui -> up|down|unknown. `unknown` is treated as resident (fail-closed).
tenant_state() {
  local script field line val
  case "$1" in
    brain)   script="$BRAIN_HARNESS";   field=brain ;;
    comfyui) script="$COMFYUI_HARNESS"; field=comfyui ;;
    *) echo "unknown"; return 0 ;;
  esac
  [ -x "$script" ] || { echo "unknown"; return 0; }
  line="$("$script" status 2>/dev/null)" || { echo "unknown"; return 0; }
  val="$(printf '%s\n' "$line" | sed -n "s/.* ${field}=\\([a-z]*\\).*/\\1/p" | head -1)"
  case "$val" in up|down) echo "$val" ;; *) echo "unknown" ;; esac
}

# Is the given tenant's server OURS? (established from the harness status line)
tenant_ours() {
  local script line
  case "$1" in
    brain)   script="$BRAIN_HARNESS" ;;
    comfyui) script="$COMFYUI_HARNESS" ;;
    *) return 1 ;;
  esac
  [ -x "$script" ] || return 1
  line="$("$script" status 2>/dev/null)" || return 1
  printf '%s\n' "$line" | grep -q 'ours=yes'
}

# --- argument parsing ---------------------------------------------------------
parse_opts() {  # sets FLOOR and WAIT; unknown args -> usage rc 1
  FLOOR=""; WAIT="$DEFAULT_WAIT"
  while [ $# -gt 0 ]; do
    case "$1" in
      --floor) FLOOR="${2:-}"; shift 2 ;;
      --wait)  WAIT="${2:-}"; shift 2 ;;
      *) echo "phase_handoff: unknown option: $1" >&2; return 1 ;;
    esac
  done
  case "$FLOOR" in
    ''|*[!0-9]*) return 0 ;;   # empty/invalid left for the caller's default
  esac
  return 0
}

default_floor() {  # $1 = render|brain
  case "$1" in
    render) echo "$PHASE_RENDER_FLOOR" ;;
    brain)  echo "$PHASE_BRAIN_FLOOR" ;;
    *)      echo "$PHASE_RENDER_FLOOR" ;;
  esac
}

# ---------------------------------------------------------------------------
# measure: device reading only (no tenant knowledge).
cmd_measure() {
  parse_opts "$@" || { echo "usage: $0 measure [--floor GIB]" >&2; return 1; }
  local floor free verdict rc
  floor="${FLOOR:-$(default_floor render)}"
  free="$(vram_free_mib)"
  verdict="$(handoff_verdict "${free:-}" "$floor" down)"; rc=$?
  echo "free=${free:-unreadable}MiB floor=${floor}GiB verdict=${verdict}"
  case "$verdict" in
    proceed) log "PROCEED — measured free ${free}MiB >= floor ${floor}GiB" ;;
    park:vram_unreadable) log "PARK — device unreadable (nvidia-smi returned nothing); fail-closed" ;;
    *) log "PARK — measured free ${free}MiB < floor ${floor}GiB; vram_insufficient" ;;
  esac
  return "$rc"
}

# ---------------------------------------------------------------------------
# check: read-only admission for entering a phase, including tenant residency.
cmd_check() {
  local phase="${1:-}"; shift || true
  case "$phase" in render|brain) ;; *) echo "usage: $0 check render|brain [--floor GIB]" >&2; return 1 ;; esac
  parse_opts "$@" || { echo "usage: $0 check render|brain [--floor GIB]" >&2; return 1; }
  local floor outgoing free tstate verdict rc
  floor="${FLOOR:-$(default_floor "$phase")}"
  [ "$phase" = "render" ] && outgoing=brain || outgoing=comfyui
  tstate="$(tenant_state "$outgoing")"
  free="$(vram_free_mib)"
  verdict="$(handoff_verdict "${free:-}" "$floor" "$tstate")"; rc=$?
  echo "phase=${phase} outgoing=${outgoing} tenant=${tstate} free=${free:-unreadable}MiB floor=${floor}GiB verdict=${verdict}"
  return "$rc"
}

# ---------------------------------------------------------------------------
# Transition core: stop the outgoing tenant (ours only, claim retained), then
# poll the DEVICE until the measured reading admits the incoming phase.
#   $1 = phase (render|brain)   remaining = --floor/--wait already parsed
cmd_transition() {
  local phase="$1"
  local outgoing incoming floor free tstate verdict rc waited=0 deadline
  if [ "$phase" = "render" ]; then outgoing=brain; incoming=comfyui; else outgoing=comfyui; incoming=brain; fi
  floor="${FLOOR:-$(default_floor "$phase")}"
  deadline=$(( $(date +%s) + WAIT ))

  # 1. Stop the outgoing tenant — ONLY if it is ours. A foreign tenant is never
  #    killed; its residency simply parks the handoff (fail-closed).
  tstate="$(tenant_state "$outgoing")"
  if [ "$tstate" = "up" ]; then
    if tenant_ours "$outgoing"; then
      log "to-${phase}: ${outgoing} resident and OURS — stopping its server, KEEPING the batch claim"
      case "$outgoing" in
        brain)   "$BRAIN_HARNESS" stop-server   >>"${TC_HANDOFF_LOG:-/dev/null}" 2>&1 || log "to-${phase}: WARN brain stop-server returned nonzero" ;;
        comfyui) "$COMFYUI_HARNESS" stop-server >>"${TC_HANDOFF_LOG:-/dev/null}" 2>&1 || log "to-${phase}: WARN comfyui stop-server returned nonzero" ;;
      esac
    else
      log "to-${phase}: ${outgoing} resident but NOT OURS — never killing a foreign tenant; handoff will park"
    fi
  elif [ "$tstate" = "down" ]; then
    log "to-${phase}: ${outgoing} already down — nothing to stop"
  else
    log "to-${phase}: ${outgoing} state UNKNOWN — fail-closed; handoff will park unless it clears"
  fi

  # 2. Poll the DEVICE. Freeness is the measured reading, never the stop's exit
  #    code and never the pid's disappearance (CUDA holds VRAM briefly after exit).
  while :; do
    tstate="$(tenant_state "$outgoing")"
    free="$(vram_free_mib)"
    verdict="$(handoff_verdict "${free:-}" "$floor" "$tstate")"; rc=$?
    case "$verdict" in
      proceed)
        log "to-${phase}: PROCEED — ${outgoing} verified ${tstate}, measured free ${free}MiB >= floor ${floor}GiB after ${waited}s. ${incoming} may start under the same claim."
        echo "phase=${phase} verdict=proceed outgoing=${outgoing} tenant=${tstate} free=${free}MiB floor=${floor}GiB"
        return 0 ;;
    esac
    if [ "$(date +%s)" -ge "$deadline" ]; then
      log "to-${phase}: PARK ${verdict} after ${waited}s (outgoing=${outgoing} state=${tstate}, measured free=${free:-unreadable}MiB, floor=${floor}GiB) — ${incoming} NOT started, batch claim retained. A refused batch is a normal outcome."
      echo "phase=${phase} verdict=${verdict} outgoing=${outgoing} tenant=${tstate} free=${free:-unreadable}MiB floor=${floor}GiB"
      return "$rc"
    fi
    sleep "$POLL_INTERVAL"; waited=$((waited + POLL_INTERVAL))
  done
}

cmd_to_render() {
  parse_opts "$@" || { echo "usage: $0 to-render [--floor GIB] [--wait SEC]" >&2; return 1; }
  cmd_transition render
}

cmd_to_brain() {
  parse_opts "$@" || { echo "usage: $0 to-brain [--floor GIB] [--wait SEC]" >&2; return 1; }
  cmd_transition brain
}

# ---------------------------------------------------------------------------
# plan: PURE offline decision. No GPU, no claim, no harness call.
cmd_plan() {
  local free="${1:-}" floor="${2:-}" tenant="${3:-down}" verdict rc
  if [ -z "$floor" ]; then echo "usage: $0 plan FREE_MIB FLOOR_GIB [up|down]" >&2; return 1; fi
  verdict="$(handoff_verdict "$free" "$floor" "$tenant")"; rc=$?
  echo "verdict=${verdict}"
  return "$rc"
}

# ---------------------------------------------------------------------------
cmd_status() {
  local b c free floor verdict
  b="$(tenant_state brain)"; c="$(tenant_state comfyui)"
  floor="$(default_floor render)"
  free="$(vram_free_mib)"
  # Status reports the RENDER admission (outgoing = brain) by default.
  verdict="$(handoff_verdict "${free:-}" "$floor" "$b")"
  echo "brain=${b} comfyui=${c} free=${free:-unreadable} floor=${floor} verdict=${verdict}"
}

case "${1:-}" in
  measure)   shift; cmd_measure "$@" ;;
  check)     shift; cmd_check "$@" ;;
  to-render) shift; cmd_to_render "$@" ;;
  to-brain)  shift; cmd_to_brain "$@" ;;
  plan)      shift; cmd_plan "$@" ;;
  status)    cmd_status ;;
  *)
    echo "usage: $0 {measure [--floor GIB]|check render|brain [--floor GIB]|to-render [--floor GIB] [--wait SEC]|to-brain [--floor GIB] [--wait SEC]|plan FREE_MIB FLOOR_GIB [up|down]|status}" >&2
    exit 1 ;;
esac
