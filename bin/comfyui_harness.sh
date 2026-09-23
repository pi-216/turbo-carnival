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
# The ask when the card is FREE. A FIT value, not a requirement: f0af66a
# (2026-09-16) set 21 because 22.4GiB was free with the desktop attached, after a
# 23GiB ask was refused all day. When the card is NOT free the ask is budgeted
# against live free memory by vram_ask_for_free() -- see the PROVEN ENVELOPE note
# there. Never assume this number is the render's footprint.
VRAM=21
VRAM_MIN_FIT=16        # GiB: below this ask no render is attempted at all
FIT_HEADROOM_MIB=1024  # MiB left free for the desktop + ComfyUI's own slack
# ComfyUI's OWN VRAM budget headroom (GiB) -> `--reserve-vram` on the launch line.
#
# WHY (measured 2026-09-22; this is the render-execution-error root cause):
# ComfyUI's dynamic-VRAM manager sizes its per-model budget from the free VRAM it
# sees, so the EMPTIER the card, the MORE it loads -- and past the card's real
# limit it OOMs instead of offloading. Same workflow, same session, same persona:
#   * co-tenants holding ~8 GiB -> "loaded partially; 15275.11 MB usable, 14914.72
#     MB loaded, 7785.37 MB offloaded" -> "Prompt executed in 95.61 seconds" (the
#     FASTEST prompts of that job: offloading is cheap on this path)
#   * card otherwise empty      -> "loaded partially; 21719.11 MB usable, 21448.72
#     MB loaded, 1251.42 MB offloaded" -> torch.OutOfMemoryError 78 MiB short at
#     21.32 GiB allocated on a 23.52 GiB device (job 7564, 2026-09-22T00:05Z),
#     with SDXL + CLIP still cached from the first stage.
# The OOM then left ComfyUI's model state broken, so the retry drew "ComfyUI API
# error: HTTP 500" from the Impact-Pack handler ('NoneType' has no attribute
# 'values'): ONE over-commit cost two failed jobs and a lost render.
# 5 GiB puts ComfyUI's budget back near ~16 GiB -- the envelope the 15.3 GiB
# "usable" render above already PROVED -- and the reserve is for ComfyUI's own
# transient sampler/inductor buffers, not for a co-tenant (we hold the claim).
# Override with COMFY_RESERVE_VRAM; see cmd_plan / the launch instrumentation.
COMFY_RESERVE_VRAM="${COMFY_RESERVE_VRAM:-5}"
# The ONE owner of ComfyUI's launch flags. The launch line, the offline `plan`
# surface and the launch instrumentation all read this array, so a flag cannot
# reach the launch path without also showing up where a GPU-free check can see
# it (bin/comfyui_harness_test.sh asserts exactly that).
COMFY_LAUNCH_ARGS=(--listen 0.0.0.0 --reserve-vram "$COMFY_RESERVE_VRAM")
DURATION=9h
COMFY_DIR=/mnt/fscache/essdee/ComfyUI
COMFY_VENV=.venv
COMFY_PORT=8188
STATE_FILE="${TC_CLAIM_FILE:-$APP_DIR/log/comfyui_claim.json}"
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

# Retire the RECORD of a job WE created by marking it `cancelled` — never by
# deleting it.
#
# release() cannot do this: it returns "not_owner" while another agent holds the
# GPU (and returns BEFORE touching the job file), so a queued-never-claimed entry
# stays status=queued and would block the next agent's front-of-queue for up to
# 24h (expire window). read_queue() only counts status=="queued", so cancelling
# unblocks the FIFO exactly as `rm` did — but `rm` also destroyed the only
# artifact tying the id to this project, leaving `job requested: <id>` in the
# scheduler's events.log with no jobs/<id>.json, which is indistinguishable from
# a LOST job (measured 2026-09-20: three such orphans cost an investigation, and
# every diagnosis recipe in the gpu-resource-scheduler skill starts by reading
# jobs/<id>.json). The cancelled record keeps request -> cancel traceable, with
# the reason, for free.
#
# Falls back to rm when the write cannot be verified: a 24h FIFO blockade is
# worse than losing one history row. Only ever called with job ids this script
# generated itself (comfyui-<ts>-<pid>[-<attempt>]).
cancel_job_record() {
  local jid="$1" reason="${2:-comfyui_harness.sh: retiring our own queued request}"
  [ -n "$jid" ] || return 0
  python3 - "$SCHED_JOBS_DIR" "$jid" "$reason" <<'PY' || rm -f "${SCHED_JOBS_DIR}/${jid}.json" 2>/dev/null || true
import datetime, json, os, socket, sys

jobs_dir, jid, reason = sys.argv[1], sys.argv[2], sys.argv[3]
path = os.path.join(jobs_dir, f"{jid}.json")
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

if not os.path.exists(path):
    sys.exit(0)                      # already gone — nothing to preserve
with open(path) as f:
    rec = json.load(f)
if rec.get("status") != "queued":
    sys.exit(0)                      # already terminal — leave that history alone

rec["status"] = "cancelled"
rec["cancelled_at"] = now
rec["cancelled_by"] = "comfyui_harness.sh"
rec["cancelled_reason"] = reason
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(rec, f, indent=2)
    f.flush()
    os.fsync(f.fileno())
os.replace(tmp, path)                # atomic: a reader never sees a partial file

# Audit line in the scheduler's OWN event log (same directory layout the
# scheduler uses, so a fixture SCHED_JOBS_DIR keeps this isolated too).
log_dir = os.path.join(os.path.dirname(os.path.abspath(jobs_dir)), "logs")
os.makedirs(log_dir, exist_ok=True)
with open(os.path.join(log_dir, "events.log"), "a") as f:
    f.write(f"{now} [info] {socket.gethostname()}: comfyui_harness.sh: "
            f"job cancelled: {jid} ({reason})\n")

with open(path) as f:                # verify the write actually took
    sys.exit(0 if json.load(f).get("status") == "cancelled" else 1)
PY
}

# Retire a job we created: release what release() can (a lease we own), then
# cancel the record so the FIFO is unblocked AND the id stays traceable.
cleanup_job() {
  local jid="$1" reason="${2:-cleanup: one outstanding request per project}"
  [ -n "$jid" ] || return 0
  sched release --gpu "$GPU" --job-id "$jid" --status failed >/dev/null 2>&1 || true
  cancel_job_record "$jid" "$reason"
  log "cleanup: retired queued request $jid (record kept as cancelled)"
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
    cleanup_job "$jid" "duplicate: one outstanding request per project"
  done
  echo "${own[0]}"
}

# The ask PERSISTED in a queue record (jobs/<id>.json -> vram_gb). `poll` re-checks
# THAT number against live free memory at CLAIM time (gpu_scheduler.py:830-855), so
# an adopted record carries whatever was right when it was minted -- not what fits
# now. Prints nothing when the record is missing/unreadable.
queued_job_vram_gb() {
  python3 - "$SCHED_JOBS_DIR" "$1" <<'PY'
import json, os, sys
jobs_dir, jid = sys.argv[1], sys.argv[2]
try:
    with open(os.path.join(jobs_dir, f"{jid}.json")) as f:
        v = json.load(f).get("vram_gb")
except Exception:
    sys.exit(0)
if isinstance(v, (int, float)) and not isinstance(v, bool):
    print(v)
PY
}

# Pure decision, offline-testable (no GPU, no claim) -- same contract as cmd_plan:
# does a persisted ask EXCEED the live-fit ask? Anything unreadable answers "no"
# so the caller KEEPS the entry: losing a FIFO place to a parse bug is worse than
# one refused window. Exit 0 = exceeds, 1 = does not (or cannot be read).
ask_exceeds() {
  python3 - "$1" "$2" <<'PY'
import sys
try:
    rec, live = float(sys.argv[1]), float(sys.argv[2])
except (TypeError, ValueError):
    sys.exit(1)
sys.exit(0 if rec > live else 1)
PY
}

log() {
  rotate_harness_log
  # Log lines go to STDERR: several callers capture a function's STDOUT as its
  # return value (`job="$(reconcile_own_queue)"`), and tee-ing the log to stdout
  # made those captures multiline. Measured 2026-09-20: cancelling a duplicate
  # turned the adopted id into "<log line>\n<log line>\n<id>", so `poll` was
  # handed a job id that does not exist and answered `not_queued` — a wasted
  # attempt and a misleading "re-requesting once" line. A function's stdout is
  # its return value; the log belongs on stderr. Cron captures both streams, so
  # nothing is lost.
  echo "[$(date '+%F %T')] $*" | tee -a "$HARNESS_LOG" >&2
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
# comfy_pid in our state file AND that record says we started it. Ownership rule:
# never kill what we did not spawn. If the state file is missing (tmpfs wipe) we
# conservatively treat it as foreign and leave it alone.
#
# `origin` (2026-09-23): an ADOPTED instance is NOT ours even though our claim
# covers it — we did not start it, we must not stop it, and calling it ours made
# the board label the operator's interactive tmux session as our leaked orphan
# (the loudest possible finding) purely because a claim had adopted it.
comfyui_ours() {
  local want pid origin
  want="$(read_state | sed -n '3p')"
  origin="$(read_state | sed -n '4p')"
  [ -n "$want" ] || return 1
  [ "$origin" = "launched" ] || return 1
  pid="$(pgrep -f 'main\.py --listen' 2>/dev/null | head -1)"
  [ -n "$pid" ] && [ "$pid" = "$want" ]
}

# The pid of whatever is serving :8188 (ours or a co-tenant's). Single owner of
# the discovery pattern so the attribution, the reserve check and the refusal
# cannot disagree about WHICH process they are talking about.
comfyui_running_pid() { pgrep -f 'main\.py --listen' 2>/dev/null | head -1; }

# Does the RUNNING ComfyUI carry the VRAM-headroom flag? The flag is the
# discriminator for the over-commit OOM (see COMFY_RESERVE_VRAM): measured across
# every no-reserve run on record, OOMs recurred at a material rate -- 3 OOMs in
# 27 renders (09-17), 3 in 12 (09-17), 6 in 35 (09-19), 3 in 3 (09-22 00:0xZ,
# the job that then drew HTTP 500 from the broken model state) -- while every
# render since the flag went on the launch line (2026-09-22 02:34Z) has had
# zero. The args are readable only from /proc, and they are the ONLY thing that
# distinguishes a renderable instance from a trap, so this is what `ensure`
# refuses on (see the guard in cmd_ensure) and what `status` reports as
# reserve=<ok|missing>. Optional PID argument so it is testable without a GPU.
comfyui_reserve_ok() {
  local pid="${1:-}" cmdline
  [ -n "$pid" ] || pid="$(comfyui_running_pid)"
  [ -n "$pid" ] || return 1
  cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
  case "$cmdline" in *--reserve-vram*) return 0 ;; esac
  return 1
}

# WHO the pid serving :8188 belongs to — operator | agent | unit | other | unknown.
# WHY: `owner=foreign` is TRUE for a human's tmux session, another project's
# supervised unit and an agent-owned orphan alike, and those three have OPPOSITE
# correct responses -- so without this the reader either hand-reads /proc (three
# consecutive ops-triage passes did, 2026-09-22) or proposes the wrong fix: the
# 19:04 EDT growth-brain tick reported the blocker as a foreign instance whose
# "clean fix is on the foreign owner's side: relaunch their ComfyUI with
# --reserve-vram" when it was the OPERATOR's own interactive session, which no
# agent may touch, restart or re-flag (measured: holder=operator, pid 553489,
# tmux-spawn-*.scope, 22.6 GiB, actively rendering).
# The classifier is owned by bin/tc_ops.py (classify_holder + holder_token, with
# their own selftest assertions); this is only the call, so the harness and the
# board can never disagree about who a pid is. Never fails the caller: a missing
# script, a timeout or an unexpected token degrades to `unknown`.
comfyui_holder_class() {
  local pid="${1:-}" out
  [ -n "$pid" ] || pid="$(comfyui_running_pid)"
  [ -n "$pid" ] || { echo unknown; return 0; }
  out="$(timeout 5 "$PY3" "$APP_DIR/bin/tc_ops.py" holder-class "$pid" 2>/dev/null | head -1)"
  case "$out" in
    operator|agent|unit|other) echo "$out" ;;
    *) echo unknown ;;
  esac
}

# The response clause for an attribution log line: the CLASS decides what may be
# done, so it is spelled out where the refusal is recorded rather than left to the
# reader to infer from a cgroup path.
holder_response_note() {
  case "${1:-}" in
    operator) echo "the OPERATOR's interactive session -- a human is using the shared install; yield the window, do not touch/restart/re-flag it (a running process's args are not ours to change)" ;;
    unit)     echo "another project's supervised unit -- its launch line is that project's to change; yield, do not touch it" ;;
    agent)    echo "one of OUR agent cgroups -- our own launch path dropped the flag; fix the launch line in this repo, not the process" ;;
    *)        echo "holder unattributable -- yield and report it; never restart an instance we did not launch" ;;
  esac
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
  local pid cg started who=foreign reserve
  pid="$(comfyui_running_pid)"
  [ -n "$pid" ] || { echo "owner=unknown"; return 0; }
  comfyui_ours && who=ours
  cg="$(sed -n 's/^0:://p' "/proc/$pid/cgroup" 2>/dev/null)"
  started="$(ps -o lstart= -p "$pid" 2>/dev/null | xargs)"
  # reserve= is the launch-arg half of the same attribution: an instance without
  # --reserve-vram cannot be rendered through (see comfyui_reserve_ok), so a
  # monitor reading `status` sees the refusal condition before a tick hits it.
  if comfyui_reserve_ok "$pid"; then reserve=ok; else reserve=missing; fi
  # holder= is the WHO half of the same attribution: owner=foreign covers a human's
  # tmux session, another project's unit and an agent orphan, and only the class
  # says which response is legal (see holder_response_note).
  echo "owner=$who pid=$pid cgroup=${cg:-?} started=${started// /_} reserve=$reserve holder=$(comfyui_holder_class "$pid")"
}

# Discover the running ComfyUI's pid and record it in the state file as ours.
# This is also the instrumentation hook: every path that ends with a live
# ComfyUI (fresh launch AND adoption of an orphan) passes through here, so the
# cgroup assertion and the telemetry sampler always start.
record_comfy_pid() {
  local job="$1" origin="${2:-launched}" cp
  cp="$(pgrep -f 'main\.py --listen' 2>/dev/null | head -1)"
  if [ -n "$cp" ]; then
    write_state "$job" "$(read_state | sed -n '2p')" "$cp" "$origin"
    log "comfy pid $cp recorded for $job (origin=$origin)"
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
  local job="$1" cp="$2" cg cmdline
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
  # Assert the VRAM-headroom flag reached the PROCESS, not just the script: this
  # is the difference between "offload the rest" and "fill the card and OOM"
  # (2026-09-22T00:05Z: 21719 MB budget -> torch OOM 78 MiB short -> the retry
  # drew HTTP 500). A launch line that silently drops it must say so HERE.
  cmdline="$(tr '\0' ' ' < "/proc/$cp/cmdline" 2>/dev/null || true)"
  case "$cmdline" in
    *--reserve-vram*)
      log "instrument: OK — ComfyUI launched with --reserve-vram ${COMFY_RESERVE_VRAM}GiB (its own budget headroom)" ;;
    *)
      log "instrument: ERROR — comfy pid $cp was launched WITHOUT --reserve-vram; it will size its VRAM budget to the whole card and OOM on a two-stage workflow (see COMFY_RESERVE_VRAM)" ;;
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
  local job="$1" last unit jl peak
  unit="comfyui-svc-${1#comfyui-}"
  if [ -f "$TELE_FILE" ]; then
    last="$(grep -F "\"job\": \"${job}\"" "$TELE_FILE" 2>/dev/null | tail -1)"
    [ -n "$last" ] || last="$(tail -1 "$TELE_FILE" 2>/dev/null)"
    log "instrument: last telemetry: ${last:-none}"
    # The number a reservation should be sized from, at the point of use: the
    # card-level high-water mark during THIS job. It counts co-tenants -- the
    # sampler reads card-level nvidia-smi memory.used -- so subtract any holder
    # that is not us before calling it our footprint. This is the surface that
    # turns "flux footprint unmeasured" into a measurement on the first render
    # (see vram_ask_for_free for the envelope already proven from ComfyUI logs).
    peak="$(grep -F "\"job\": \"${job}\"" "$TELE_FILE" 2>/dev/null \
            | sed -n 's/.*"vram_used_mib": *\([0-9][0-9]*\).*/\1/p' | sort -n | tail -1)"
    if [ -n "$peak" ]; then
      log "instrument: card-level VRAM peak for $job: ${peak}MiB (co-tenants INCLUDED; outside-scheduler holders now: $(vram_holders))"
    fi
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

# --- Adaptive fit: budget the ask against live free memory --------------------
# WHY (root-caused 2026-09-21, after 18h of render starvation reported by 6 ticks
# as "needs a human decision"): the fixed 21GiB ask is a FIT value, and the
# consumer does NOT need a near-empty card. ComfyUI's dynamic loader sizes the
# UNet to whatever is free at load time and offloads the remainder, and this
# install has ALREADY rendered this exact workflow with a much smaller footprint.
# PROVEN ENVELOPE (comfyui-comfyui-variety-1789685009.log, 2026-09-17 -- same
# ComfyUI install, same flux1-krea-dev UNet, same 824x1024/1024x1024 workflow):
#   loaded partially; 15275.15 MB usable, 14914.77 MB loaded, 7785.37 MB offloaded
#   -> [INFO] Prompt executed in 95.61 seconds
#   loaded partially; 15498.09 MB usable, 15132.32 MB loaded, 7567.81 MB offloaded
#   -> [INFO] Prompt executed in 89.93 seconds
#   (four such loads, 79.9-95.6s each -- the FASTEST prompts of that job; a ~15GiB
#    resident UNet with ~7.5GiB streamed from CPU RAM is a working configuration,
#    not a degraded one. The card held ~8GiB of co-tenants at the time.)
# So the render needs roughly 16.3GiB FREE at load, and the 21GiB ask only
# guarantees it by requiring an almost-empty card. Measured 2026-09-21: the 4090
# sat at 18.5GiB free / 0% busy with an EMPTY scheduler queue while an idle
# co-tenant (BreastTissue-Net labeler, 4.6GiB, outside the scheduler) held the
# rest -- and every tick refused to render.
# vram_ask_for_free() therefore asks for what is actually free, minus headroom,
# never more than the full ask and never less than VRAM_MIN_FIT.
#
# WHY the below-floor case asks the FLOOR and not the full ask (fixed 2026-09-21,
# completing the fix above): the ask is PERSISTED in the queue record
# (jobs/<id>.json -> vram_gb) and re-checked by `poll` at CLAIM time against a
# DIFFERENT free reading -- the card as it is once the current occupant has
# released. Minting the full 21GiB while another job occupies the card therefore
# guarantees a self-inflicted refusal later: measured 2026-09-21, the 08:03 tick
# asked 21GiB while prx-tg-pixel-posttrain-v3 held 16GiB (`plan 8192` -> ask=21GiB)
# and that record is then refused for the whole of its life against the ~18.9GiB
# actually free once the occupant releases -- the exact refusal already in this
# log from the 01:04-06:05 ticks: "free=18949MiB vs requested 21GiB". The entry is
# then given up at the FIFO head and re-requested on the NEXT tick, so the cost is
# a whole render window per occurrence.
# The ADOPTION half was fixed the same day (measured live 09:01:09: ask=16GiB but
# the adopted entry's record said 21GiB): cmd_ensure now retires an adopted own
# entry whose PERSISTED ask exceeds the live-fit ask and re-requests at the live
# ask, so a record minted under an older policy cannot keep the loop refusing.
# Asking the floor instead costs nothing: `poll` still refuses anything below the
# ask, so "nothing is attempted below the floor" is unchanged -- the record is
# simply claimable at the floor the moment the card frees to it. The floor is the
# smallest ask this install treats as workable; the measured load requirement is
# ~16.3GiB free (envelope above), so the 16.0-16.3GiB sliver is the only case
# where a claim can now land marginally under it (raise VRAM_MIN_FIT if that ever
# bites -- it is the single knob).
vram_ask_for_free() {
  local free_mib="$1" full="$VRAM" eff
  case "$free_mib" in ''|*[!0-9]*) echo "$full"; return 0 ;; esac
  # Card effectively free -> the known-good full ask, behaviour unchanged.
  if [ "$free_mib" -ge $((full * 1024)) ]; then echo "$full"; return 0; fi
  eff=$(( (free_mib - FIT_HEADROOM_MIB) / 1024 ))
  # Too tight for a reduced ask: carry the FLOOR, not the full ask, so the queued
  # record stays claimable once the occupant releases (see WHY above).
  if [ "$eff" -lt "$VRAM_MIN_FIT" ]; then echo "$VRAM_MIN_FIT"; return 0; fi
  echo "$eff"
}

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
  # echo job_id, heartbeat_pid, comfy_pid, origin from state file (empty if absent)
  python3 - "$STATE_FILE" <<'PY'
import json, sys, os
p = sys.argv[1]
if os.path.exists(p):
    try:
        d = json.load(open(p))
        print(d.get("job_id", ""))
        print(d.get("heartbeat_pid", ""))
        print(d.get("comfy_pid", ""))
        print(d.get("origin", ""))
        sys.exit(0)
    except Exception:
        pass
print("")
print("")
print("")
print("")
PY
}

write_state() {
  # args: job_id heartbeat_pid [comfy_pid] [origin]
  # `origin` is the OWNERSHIP discriminator: "launched" (we started it in this
  # lease) vs "adopted" (it was already answering when we took the claim).
  # Without it, adoption records a CO-TENANT's pid as ours, and then both the
  # leak report and the tick-end kill treat someone else's session as ours.
  python3 - "$STATE_FILE" "$1" "$2" "${3:-}" "${4:-}" <<'PY'
import json, sys
json.dump({"job_id": sys.argv[2], "heartbeat_pid": sys.argv[3],
           "comfy_pid": sys.argv[4], "origin": sys.argv[5]},
          open(sys.argv[1], "w"))
PY
}

# PURE decision (no side effects): may we SIGTERM this instance?
#   args: origin pid stage   (stage: live | gone | not-comfyui)
# prints "kill" or "refuse:<reason>"; rc 0 = may kill.
# This is the single owner of the ownership rule, so the kill path and the audit
# surface can never disagree about it (same shape as vram_ask_for_free/plan).
kill_verdict() {
  local origin="$1" pid="$2" stage="${3:-live}"
  if [ -z "$pid" ]; then echo "refuse:no-recorded-pid"; return 1; fi
  if [ "$origin" != "launched" ]; then echo "refuse:not-launched-by-us"; return 1; fi
  case "$stage" in
    gone)        echo "refuse:already-gone"; return 1 ;;
    not-comfyui) echo "refuse:pid-reuse"; return 1 ;;
  esac
  echo "kill"
  return 0
}

# Kill ONLY the instance we started in this lease.
#
# WHY (2026-09-23): this used to `pgrep -f 'main\.py --listen'` and SIGTERM (then
# SIGKILL) EVERY match. That pattern matches every ComfyUI on the box -- the
# operator's interactive tmux session, another project's supervised unit, any
# port -- and this function is reached from the tick-end `shutdown` that follows
# an ADOPTED instance (ensure adopts a foreign instance that carries
# --reserve-vram, and launch_comfyui records its pid). So the sequence the board
# itself recommends -- "relaunch your session WITH --reserve-vram so the harness
# can adopt it" -- armed a kill of that very session at the end of our next tick:
# a hard-constraint violation (never touch another project's/operator's work)
# reachable from an ordinary render tick, with no error anywhere.
#
# The ownership rule (Tim, 2026-09-07) is: never kill what we did not spawn. It
# is now enforced at the choke point -- our recorded pid, our recorded origin --
# instead of relying on every caller to have checked first.
kill_comfyui() {
  local pid origin stage v
  pid="$(read_state | sed -n '3p')"
  origin="$(read_state | sed -n '4p')"
  stage="live"
  if [ -n "$pid" ]; then
    if ! kill -0 "$pid" 2>/dev/null; then
      stage="gone"
    elif ! tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q 'main\.py --listen'; then
      stage="not-comfyui"
    fi
  fi
  v="$(kill_verdict "$origin" "$pid" "$stage")"
  if [ "$v" != "kill" ]; then
    case "$v" in
      refuse:no-recorded-pid)
        log "ComfyUI: NOT killed — no comfy_pid in our state file, so there is no instance we can prove we started (a pgrep sweep here would kill a co-tenant's; OUR orphan does have a recorded pid, and ensure's self-heal is the path that stops it)" ;;
      refuse:not-launched-by-us)
        log "ComfyUI: NOT killed — pid $pid was ADOPTED (origin=${origin:-unrecorded}), not launched by us in this lease; whoever started it owns stopping it" ;;
      refuse:already-gone)
        log "ComfyUI: pid $pid already gone" ;;
      refuse:pid-reuse)
        log "ComfyUI: NOT killed — pid $pid no longer looks like a ComfyUI (pid reuse); refusing" ;;
      *)
        log "ComfyUI: NOT killed — ownership verdict $v" ;;
    esac
    return 0
  fi
  log "ComfyUI: SIGTERM to our pid $pid (origin=launched)"
  kill -TERM "$pid" 2>/dev/null
  local waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 30 ]; do
    sleep 2; waited=$((waited + 2))
  done
  if kill -0 "$pid" 2>/dev/null; then
    log "ComfyUI: still alive after TERM, SIGKILL"
    kill -KILL "$pid" 2>/dev/null
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

  # Budget the ask against live free memory BEFORE requesting. Requesting the
  # full 21GiB on a card with 18.5GiB free is a guaranteed `vram_insufficient`,
  # and that refusal is what the whole render loop then reports as "the GPU is
  # unavailable" while the card sits idle (see vram_ask_for_free).
  local free_mib ask
  free_mib="$(vram_free_mib)"
  ask="$(vram_ask_for_free "$free_mib")"
  VRAM_ASK="$ask"
  if [ "$ask" != "$VRAM" ]; then
    log "ensure: adaptive fit — free=${free_mib}MiB < full ask ${VRAM}GiB, so asking ${ask}GiB (headroom ${FIT_HEADROOM_MIB}MiB, floor ${VRAM_MIN_FIT}GiB). ComfyUI sizes the UNet to free VRAM and offloads the rest (proven: a 14.9GiB resident flux UNet rendered in 95.6s, comfyui-variety-1789685009.log)."
  fi

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
    elif comfyui_reserve_ok; then
      log "ensure: unclaimed ComfyUI NOT launched by us (foreign) — leaving it untouched; acquiring claim to adopt it"
    else
      log "ensure: unclaimed FOREIGN ComfyUI (pid $(comfyui_running_pid)) was launched WITHOUT --reserve-vram — NOT adopting it (see the refusal below)"
    fi
  fi

  # INVARIANT (2026-09-22): never submit a render to a ComfyUI that was not
  # launched with --reserve-vram. Adoption is the hole this closes: a running
  # instance answering :8188 is adopted rather than relaunched (queue-first,
  # 2026-09-07) so the launch line is NOT ours to choose -- and a co-tenant's
  # tmux ComfyUI (observed 2026-09-22 12:57 EDT: `--listen 0.0.0.0
  # --enable-manager`, no reserve, 17.1 GiB held) would then run OUR two-stage
  # flux workflow at a budget sized to the whole card, which is precisely the
  # over-commit that OOMed 78 MiB short at 00:05Z and then drew HTTP 500 from
  # the broken model state. We cannot change a running process's args and a
  # foreign instance is not ours to restart, so the only correct move is to yield
  # the window -- and to yield it BEFORE requesting a claim, so the refusal costs
  # nothing but the hour (the queue absorbs it: see `tc_ops.py queue` dry_out=).
  # This fires on the ARGS, not on ownership: a launch line that drops the flag
  # must stop the render wherever it came from.
  if comfyui_up && ! comfyui_reserve_ok; then
    local rpid rholder
    rpid="$(comfyui_running_pid)"
    rholder="$(comfyui_holder_class "$rpid")"
    log "ensure: REFUSING this tick — ComfyUI is up (pid $rpid, owner $(comfyui_ours && echo ours || echo foreign), holder=$rholder) but was launched WITHOUT --reserve-vram; rendering through it re-arms the over-commit OOM (see COMFY_RESERVE_VRAM). Holder: $(holder_response_note "$rholder"). No claim requested, nothing to release, no render attempted."
    return 2
  fi

  # GPU held by another agent (or we never had a job): adopt our own queued
  # entry if we have one (it holds the best FIFO position), else request fresh.
  local job="" attempts=0 result=""
  while [ "$attempts" -lt 2 ]; do
    attempts=$((attempts + 1))
    job="$(reconcile_own_queue)"
    if [ -n "$job" ]; then
      # An adopted record's ask was minted at ITS request time, and `poll`
      # re-checks that persisted number against live free memory at CLAIM time
      # (not against the ask computed above). So adopting a record that asks more
      # than the live fit re-arms, on every tick, exactly the self-inflicted
      # refusal the adaptive ask exists to prevent. Measured live 2026-09-21
      # 09:01:09: "adaptive fit ... asking 16GiB" followed by "adopting our own
      # queued entry comfyui-1789992236-4075726-1", whose record asks 21GiB --
      # refused at the FIFO head the moment the occupant released (~18.9GiB free)
      # and re-requested a whole window later. Retire ONLY when the record
      # genuinely exceeds the live-fit ask; equal or smaller keeps our place.
      local adopted_ask
      adopted_ask="$(queued_job_vram_gb "$job")"
      if ask_exceeds "$adopted_ask" "$ask"; then
        log "ensure: adopted entry $job asks ${adopted_ask}GiB > live-fit ask ${ask}GiB — retiring it and re-requesting at ${ask}GiB so the record is claimable at what is free"
        cleanup_job "$job" "ask ${adopted_ask}GiB above the live-fit ask ${ask}GiB"
        job=""
      fi
    fi
    if [ -z "$job" ]; then
      # `-${attempts}` keeps the id unique across the retry below: a retired id
      # is single-use forever (request raises FileExistsError), so re-minting the
      # same <ts>-<pid> inside the same second would fail the request and skip
      # the tick.
      job="comfyui-$(date +%s)-$$-${attempts}"
      log "ensure: requesting claim $job (vram ${ask}GB, duration ${DURATION})"
      sched request --gpu "$GPU" --project "$PROJECT" --vram "$ask" --duration "$DURATION" --job-id "$job" >/dev/null 2>&1 || { log "ensure: request failed"; return 2; }
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
    log "ensure: why — free=$(vram_free_mib)MiB vs requested ${ask}GiB; holders: $(vram_holders)"
    # Provenance (verified 2026-09-21 by git blame + the sampler itself): ${VRAM}
    # is a FIT value, NOT a measured flux footprint. f0af66a (2026-09-16) set it
    # to 21 because 22.4GiB was free with the desktop attached, after a 23GiB ask
    # returned vram_insufficient all day. The "23.2GiB peak" is the SAMPLER's
    # CARD-level nvidia-smi memory.used high-water mark from 2026-09-19 -- a
    # session that was ALSO dispatching the deprecated-pipeline pony/SDXL
    # duplicate renders (the contention OOM, root-caused and fixed that same
    # day) -- so it counts co-tenants and cannot be this value's source anyway
    # (23.2 > 21).
    # Since 2026-09-21 the ask is budgeted against live free memory
    # (vram_ask_for_free: free minus headroom, clamped to [floor, full]), so
    # reaching THIS branch now means something specific and worth naming: free
    # VRAM is below the ask at CLAIM time -- the card is genuinely too full for
    # even the smallest render proven to work here, and the ask cannot have been
    # padded (it is never above live-free-minus-headroom). Name the holder and
    # move on; do not re-derive the cause by hand.
    log "ensure: note — free is below the ${ask}GiB ask at claim time (floor ${VRAM_MIN_FIT}GiB, full ask ${VRAM}GiB), so no render is attempted this tick (${VRAM}GiB is a FIT value, f0af66a 2026-09-16, not a footprint)"
  fi
  # Keep the entry ONLY while we are waiting our turn behind an earlier queued
  # job: that is normal FIFO waiting and deleting it would only lose our place
  # (and re-mint a fresh id behind ourselves next tick -- the flood). When we are
  # at the HEAD and still cannot take the card (idle but short of VRAM, a
  # co-tenant holding memory outside the scheduler, thermal, unhealthy), holding
  # the head would block SMALLER jobs behind us that could run, so give the place
  # up and let the next tick re-request.
  if [ "${result:-}" != "not_my_turn" ]; then
    cleanup_job "$job" "gave up the FIFO head (${result:-unknown}) so a job behind us can take the card"
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
    bash -c "while true; do $PY3 $SCHEDULER_PY heartbeat --gpu $GPU --job-id $job --progress 1 --vram-used ${VRAM_ASK:-$VRAM} >>$HARNESS_LOG 2>&1; sleep $HEARTBEAT_INTERVAL; done" >/dev/null 2>&1
  pid="$(systemctl --user show -p MainPID --value "$unit" 2>/dev/null)"
  case "$pid" in ''|0) pid="" ;; esac
  write_state "$job" "$pid"
  log "heartbeat unit ${unit} started (MainPID ${pid:-?}) for $job — every ${HEARTBEAT_INTERVAL}s"
}

# The launch-layer runtime probe, anchored to the SAME cwd the launch uses.
# `comfy` is ComfyUI's OWN application package (it is not installed into the
# venv), so it is importable only from the app directory: `python -c` puts the
# CWD on sys.path, and the launch itself runs with cwd=$COMFY_DIR. Probing from
# the harness's own cwd therefore FAILS ON A HEALTHY VENV -- measured 2026-09-21:
#   repo root  -> ModuleNotFoundError: No module named 'comfy'
#   $COMFY_DIR -> OK
# That turned this gate into a permanent false alarm: every launch logged
# "ERROR — import still failing after pip install; launch will likely fail" and
# ran a pointless pip install, so the ONE case it exists for (requirements.txt
# pin drift, e.g. comfy-aimdo 0.5.3 vs 0.5.5 -> "No module named
# 'comfy_aimdo.storage'") was indistinguishable from the alarm that never stops.
# tc_ops.py's own probe (check_launch_deps_importable) has always passed
# cwd=COMFY_DIR; the two surfaces must answer the same question the same way, and
# `tc_ops.py selftest` now asserts they agree.
comfy_runtime_import_ok() {
  local py="$COMFY_DIR/${COMFY_VENV}/bin/python"
  [ -x "$py" ] || return 1
  ( cd "$COMFY_DIR" && "$py" -c 'import comfy.storage' ) >/dev/null 2>&1
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
  comfy_runtime_import_ok && return 0
  log "deps: ComfyUI runtime import FAILED — provisioning venv (pip install)"
  local f
  for f in requirements.txt manager_requirements.txt; do
    [ -f "$COMFY_DIR/$f" ] || continue
    ( cd "$COMFY_DIR" && "$pip" install -r "$f" ) >>"$HARNESS_LOG" 2>&1 || \
      log "deps: WARN pip install -r $f returned nonzero"
  done
  if comfy_runtime_import_ok; then
    log "deps: venv provisioned OK — runtime import now succeeds"
  else
    log "deps: ERROR — import still failing after pip install; launch will likely fail"
  fi
}

launch_comfyui() {
  local job="$1"
  ensure_comfyui_deps
  # Adopt-or-launch: if a ComfyUI is already answering on the port (foreign
  # or adopted orphan), record its pid — never spawn a second instance that
  # would fail to bind (queue-first adoption, 2026-09-07). The record carries
  # origin=adopted, so "covered by our claim" never becomes "ours to kill".
  if comfyui_up; then
    log "launch_comfyui: ComfyUI already answering — adopting existing instance for $job (origin=adopted: our claim covers it, we did not start it, so the tick-end shutdown must NOT stop it)"
    record_comfy_pid "$job" adopted
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
  # 2026-09-22: --reserve-vram IS part of the known-good line now (see
  # COMFY_RESERVE_VRAM). It is not a compensating flag: it removes an over-commit
  # ComfyUI makes on its own when the card is empty, measured from this install's
  # own log (21719 MB "usable" -> OOM; 15275 MB "usable" -> 95.6s render).
  log "launching ComfyUI (${COMFY_DIR}) in unit ${unit} (MemoryMax=${COMFY_MEM_MAX}) args='${COMFY_LAUNCH_ARGS[*]}' — log: ${slog}"
  systemd-run --user --unit="$unit" --collect \
    --property MemoryMax="${COMFY_MEM_MAX}" --property MemoryAccounting=yes \
    --property StandardOutput=append:"$slog" --property StandardError=append:"$slog" \
    --working-directory "$COMFY_DIR" \
    "$COMFY_DIR/${COMFY_VENV}/bin/python" main.py "${COMFY_LAUNCH_ARGS[@]}" >/dev/null 2>&1 \
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
    sched heartbeat --gpu "$GPU" --job-id "$job_id" --progress 1 --vram-used "${VRAM_ASK:-$VRAM}" 2>&1 | tee -a "$HARNESS_LOG"
  else
    log "heartbeat: no active claim in state file"
    return 2
  fi
}

cmd_shutdown() {
  local job_id hb_pid comfy_pid origin
  job_id="$(read_state | head -1)"
  hb_pid="$(read_state | sed -n '2p')"
  comfy_pid="$(read_state | sed -n '3p')"
  # Read BEFORE the state file is removed below: the tail of this function reports
  # whether the port is still answering, and "still answering" means two opposite
  # things depending on whether the instance was ours (a failed stop -> WARNING)
  # or adopted (expected: it belongs to whoever started it).
  origin="$(read_state | sed -n '4p')"

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

  # Record the INTENT in the telemetry stream BEFORE the SIGTERM. A dead pid
  # cannot hold VRAM, so the sampler's exit record can never say whether a stop
  # was ours -- and its card-level vram_used_mib (co-tenants included) is exactly
  # the number a naive check reads as "leaked VRAM". Measured false positive
  # 2026-09-22 00:16:54 on a CLEAN shutdown after a render that completed.
  # tc_ops.py -> exit_was_intentional() reads this record; keep the key stable.
  if [ -f "$TELE_FILE" ]; then
    printf '{"ts": "%s", "pid": %s, "job": "%s", "intent": "shutdown"}\n' \
      "$(date +%FT%T%z)" "${comfy_pid:-0}" "${job_id:-}" >> "$TELE_FILE"
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
    if [ "$origin" = "launched" ]; then
      log "shutdown: WARNING port ${COMFY_PORT} still answering after stopping OUR instance"
    else
      log "shutdown: adopted instance (origin=${origin:-unrecorded}, pid ${comfy_pid:-none}) left RUNNING on port ${COMFY_PORT} — expected, not ours to stop. Our claim was released above; the next ensure adopts it again (or yields to it)."
    fi
  elif gpu_idle; then
    log "shutdown: clean — port closed, GPU idle (VRAM ${vm} MiB)"
  else
    log "shutdown: port closed but GPU NOT idle (VRAM ${vm} MiB) — check scheduler"
  fi
}

# Offline decision surface: what would `ensure` ask for, given a free-MiB reading?
# The reading is an argument so this can be exercised with NO GPU and no claim --
# it is what makes the fit policy testable, and what tc_ops.py cross-checks its
# own mirror of the formula against (selftest), so the two cannot drift apart.
cmd_plan() {
  local free_mib="${1:-}" ask
  [ -n "$free_mib" ] || free_mib="$(vram_free_mib)"
  ask="$(vram_ask_for_free "$free_mib")"
  echo "free=${free_mib}MiB full_ask=${VRAM}GiB min_fit=${VRAM_MIN_FIT}GiB headroom=${FIT_HEADROOM_MIB}MiB ask=${ask}GiB launch_args=${COMFY_LAUNCH_ARGS[*]}"
}

# Read-only verdict of the launch-layer runtime gate (no pip, no GPU, no claim).
# Offline surface on purpose: the deps gate is the thing that decides whether a
# claim is worth taking, so it has to be answerable without one -- and it is what
# `tc_ops.py selftest` cross-checks its own import probe against, so the launcher
# and the board can never disagree about the venv again.
cmd_deps() {
  local py="$COMFY_DIR/${COMFY_VENV}/bin/python"
  if [ ! -x "$py" ]; then
    echo "deps: UNKNOWN — no venv python at $py"
    return 2
  fi
  if comfy_runtime_import_ok; then
    echo "deps: OK — 'import comfy.storage' succeeds from $COMFY_DIR"
    return 0
  fi
  echo "deps: FAILED — 'import comfy.storage' fails from $COMFY_DIR (venv drift; ensure would pip-install and a launch would crash)"
  return 3
}

cmd_killverdict() {
  # Offline: `killverdict <origin> <pid> [stage]` -> "kill" | "refuse:<reason>".
  # Exists so the ownership rule can be exercised (and audited) with no GPU, no
  # state file and no process: the alternative -- reading the shell for a `kill` --
  # is how a pgrep sweep survived in a production shutdown path unnoticed.
  local origin="${1:-}" pid="${2:-}" stage="${3:-live}"
  kill_verdict "$origin" "$pid" "$stage"
}

case "${1:-}" in
  status)    cmd_status ;;
  ensure)    shift; cmd_ensure "$@" ;;
  heartbeat) cmd_heartbeat ;;
  telemetry) shift; cmd_telemetry "$@" ;;
  plan)      shift; cmd_plan "$@" ;;
  deps)      cmd_deps ;;
  shutdown)  cmd_shutdown ;;
  ownqueue)  own_queued_jobs ;;
  reconcile) reconcile_own_queue ;;
  killverdict) shift; cmd_killverdict "$@" ;;
  *)
    echo "usage: $0 {status|ensure [--wait SECONDS]|heartbeat|telemetry [N]|plan [FREE_MIB]|deps|shutdown|ownqueue|reconcile|killverdict ORIGIN PID [STAGE]}" >&2
    exit 1 ;;
esac