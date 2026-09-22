#!/bin/bash
# =============================================================================
# comfyui_harness_test.sh — fixture test for the harness's QUEUE-RETIREMENT and
# STDOUT-CAPTURE contract. No GPU, no live scheduler: it points the harness at a
# throwaway jobs dir (TC_SCHED_JOBS_DIR / TC_HARNESS_LOG) and stubs `sched`, so
# it is safe to run at any time, including from a cron tick.
#
# Why this test exists (both were live defects, fixed 2026-09-20):
#
#   1. RETIREMENT MUST KEEP THE RECORD. `release` cannot retire a
#      queued-never-claimed entry (it returns "not_owner" before touching the job
#      file while a co-tenant holds the GPU), so the harness retires it itself.
#      It used to `rm` the file: that unblocked the FIFO but left
#      `job requested: <id>` in the scheduler's events.log with no
#      jobs/<id>.json — indistinguishable from a LOST job, and every diagnosis
#      recipe in the gpu-resource-scheduler skill starts by reading that file.
#      It must now mark the record `cancelled` (still invisible to read_queue,
#      which only counts status=="queued") and log the cancellation.
#
#   2. LOG LINES MUST NOT LAND ON STDOUT. Callers capture a function's stdout as
#      its return value — `job="$(reconcile_own_queue)"` — and `log()` used to
#      tee to stdout, so cancelling a duplicate turned the adopted id into
#      "<log line>\n<log line>\n<id>". `poll` was then handed a nonexistent job
#      id and answered `not_queued`, costing an attempt and logging a misleading
#      "re-requesting once". log() now writes to stderr.
#
# Usage: bin/comfyui_harness_test.sh   (exit 0 = all assertions pass)
# =============================================================================
set -u

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/comfyui-harness-test.XXXXXX")"
SCHED="$SCRATCH/sched"
FAILED=0

cleanup() { [ -n "${SCRATCH:-}" ] && rm -rf -- "$SCRATCH"; }
trap cleanup EXIT

# --- fixtures: our oldest entry (adopted), our duplicate (cancelled), another
# --- project's entry (untouched), a terminal record (untouched).
python3 - "$SCHED/jobs" <<'PY'
import json, os, sys
d = sys.argv[1]
os.makedirs(d, exist_ok=True)

def w(name, **kw):
    rec = {"id": name[:-5], "project": "turbo-carnival", "gpu": "4090",
           "vram_gb": 21.0, "duration_h": 9.0, "status": "queued",
           "requested_at": "2026-09-20T19:01:03Z", "submitted_by": "test",
           "consecutive_failures": 0}
    rec.update(kw)
    with open(os.path.join(d, name), "w") as f:
        json.dump(rec, f, indent=2)

w("tc-old.json")
w("tc-new.json", requested_at="2026-09-20T20:00:54Z")
w("other.json", project="prx-tg-pixel-posttrain", requested_at="2026-09-20T18:13:02Z")
w("done.json", status="completed")
PY

export TC_SCHED_JOBS_DIR="$SCHED/jobs" TC_HARNESS_LOG="$SCRATCH/harness.log"

ok()   { printf '  PASS  %s\n' "$1"; }
bad()  { printf '  FAIL  %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; FAILED=1; }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
field() { python3 -c "import json;print(json.load(open('$1')).get('$2'))"; }

echo "--- reconcile: adopt the oldest own entry, cancel the duplicate ---"
bash -c '
  source '"$APP_DIR"'/bin/comfyui_harness.sh ownqueue >/dev/null 2>&1
  sched() { :; }              # never touch the live scheduler
  printf "%s" "$(reconcile_own_queue)"
' > "$SCRATCH/out" 2> "$SCRATCH/err"

is "captured value is exactly the adopted id" "tc-old" "$(cat "$SCRATCH/out")"
is "cancellation logged to stderr" "1" "$(grep -c 'cancelling duplicate' "$SCRATCH/err")"
is "duplicate record kept, marked cancelled" "cancelled" "$(field "$SCHED/jobs/tc-new.json" status)"
is "cancellation reason recorded" "duplicate: one outstanding request per project" \
   "$(field "$SCHED/jobs/tc-new.json" cancelled_reason)"
is "cancellation actor recorded" "comfyui_harness.sh" "$(field "$SCHED/jobs/tc-new.json" cancelled_by)"
is "adopted entry left queued" "queued" "$(field "$SCHED/jobs/tc-old.json" status)"
is "another project's entry untouched" "queued" "$(field "$SCHED/jobs/other.json" status)"
is "terminal entry untouched" "completed" "$(field "$SCHED/jobs/done.json" status)"
is "cancellation recorded in the scheduler event log" "1" \
   "$(grep -c 'job cancelled: tc-new' "$SCHED/logs/events.log")"

echo "--- reconcile again: nothing left to cancel, id still clean ---"
bash -c '
  source '"$APP_DIR"'/bin/comfyui_harness.sh ownqueue >/dev/null 2>&1
  sched() { :; }
  printf "%s" "$(reconcile_own_queue)"
' > "$SCRATCH/out2" 2>/dev/null
is "captured value is exactly the adopted id" "tc-old" "$(cat "$SCRATCH/out2")"

echo "--- status still writes exactly one stdout line ---"
bash "$APP_DIR/bin/comfyui_harness.sh" status > "$SCRATCH/status.out" 2> "$SCRATCH/status.err"
is "one stdout line" "1" "$(wc -l < "$SCRATCH/status.out")"
printf '  stdout: %s\n' "$(cat "$SCRATCH/status.out")"

echo "--- offline: the persisted-ask decision (no GPU, no claim) ---"
bash -c '
  source '"$APP_DIR"'/bin/comfyui_harness.sh ownqueue >/dev/null 2>&1
  ask_exceeds 21 16   && printf "1" || printf "0"
  ask_exceeds 16 16   && printf "1" || printf "0"
  ask_exceeds 15.5 16 && printf "1" || printf "0"
  ask_exceeds "" 16   && printf "1" || printf "0"
  ask_exceeds 21.0 16 && printf "1" || printf "0"
' > "$SCRATCH/decisions" 2>/dev/null
is "ask_exceeds 21>16 / 16=16 / 15.5<16 / unreadable / 21.0>16" "10001" "$(cat "$SCRATCH/decisions")"

bash -c '
  source '"$APP_DIR"'/bin/comfyui_harness.sh ownqueue >/dev/null 2>&1
  printf "%s" "$(queued_job_vram_gb tc-old)"
' > "$SCRATCH/readvram" 2>/dev/null
is "queued_job_vram_gb reads the record" "21.0" "$(cat "$SCRATCH/readvram")"

# --- ensure(): an adopted record whose ask EXCEEDS the live fit is retired and
# --- re-requested at the live ask (the defect measured live 2026-09-21 09:01:09:
# --- ask=16GiB while the adopted record asked 21GiB).
echo "--- ensure: stale adopted ask (21GiB) retired, re-requested at 16GiB ---"
python3 - "$SCHED/jobs2" <<'PY'
import json, os, sys
d = sys.argv[1]
os.makedirs(d, exist_ok=True)
rec = {"id": "tc-stale", "project": "turbo-carnival", "gpu": "4090",
       "vram_gb": 21.0, "duration_h": 9.0, "status": "queued",
       "requested_at": "2026-09-21T12:03:56Z", "submitted_by": "test",
       "consecutive_failures": 0}
json.dump(rec, open(os.path.join(d, "tc-stale.json"), "w"), indent=2)
PY
TC_SCHED_JOBS_DIR="$SCHED/jobs2" TC_HARNESS_LOG="$SCRATCH/ensure.log" \
  bash -c '
  source '"$APP_DIR"'/bin/comfyui_harness.sh ownqueue >/dev/null 2>&1
  STATE_FILE="'"$SCRATCH"'/claim.json"; rm -f "$STATE_FILE"
  vram_free_mib() { echo 13145; }          # -> eff 11GiB < floor, so ask=16GiB
  comfyui_up() { return 1; }               # down
  gpu_idle() { return 0; }
  sched() { printf "%s\n" "$*" >> "'"$SCRATCH"'/sched.calls"
            case "$1" in poll) echo not_my_turn ;; *) : ;; esac; return 0; }
  cmd_ensure --wait 5; exit 0
' > "$SCRATCH/ensure.out" 2>/dev/null
is "stale record retired (cancelled)" "cancelled" "$(field "$SCHED/jobs2/tc-stale.json" status)"
is "retirement reason names the live-fit ask" "ask 21.0GiB above the live-fit ask 16GiB" \
   "$(field "$SCHED/jobs2/tc-stale.json" cancelled_reason)"
is "re-requested at the live-fit ask, not 21" "1" \
   "$(grep -c 'request --gpu 4090 --project turbo-carnival --vram 16 ' "$SCRATCH/sched.calls")"
is "no 21GiB request issued" "0" "$(grep -c -- '--vram 21 ' "$SCRATCH/sched.calls")"
is "retirement logged" "1" "$(grep -c 'retiring it and re-requesting at 16GiB' "$SCRATCH/ensure.log")"
is "fresh id differs from the retired one" "1" \
   "$(grep -c 'request --gpu 4090 --project turbo-carnival --vram 16 --duration 9h --job-id comfyui-' "$SCRATCH/sched.calls")"

# --- ensure(): a record whose ask FITS the live ask keeps its FIFO place.
echo "--- ensure: adopted ask (16GiB) fits — kept, no request minted ---"
python3 - "$SCHED/jobs3" <<'PY'
import json, os, sys
d = sys.argv[1]
os.makedirs(d, exist_ok=True)
rec = {"id": "tc-fits", "project": "turbo-carnival", "gpu": "4090",
       "vram_gb": 16.0, "duration_h": 9.0, "status": "queued",
       "requested_at": "2026-09-21T12:03:56Z", "submitted_by": "test",
       "consecutive_failures": 0}
json.dump(rec, open(os.path.join(d, "tc-fits.json"), "w"), indent=2)
PY
rm -f "$SCRATCH/sched.calls"
TC_SCHED_JOBS_DIR="$SCHED/jobs3" TC_HARNESS_LOG="$SCRATCH/ensure2.log" \
  bash -c '
  source '"$APP_DIR"'/bin/comfyui_harness.sh ownqueue >/dev/null 2>&1
  STATE_FILE="'"$SCRATCH"'/claim2.json"; rm -f "$STATE_FILE"
  vram_free_mib() { echo 13145; }
  comfyui_up() { return 1; }
  gpu_idle() { return 0; }
  sched() { printf "%s\n" "$*" >> "'"$SCRATCH"'/sched.calls"
            case "$1" in poll) echo not_my_turn ;; *) : ;; esac; return 0; }
  cmd_ensure --wait 5; exit 0
' > "$SCRATCH/ensure2.out" 2>/dev/null
is "fitting record kept queued (FIFO place held)" "queued" "$(field "$SCHED/jobs3/tc-fits.json" status)"
is "no request minted when the record fits" "0" "$(grep -c ' request ' "$SCRATCH/sched.calls")"
is "kept-for-next-tick logged" "1" "$(grep -c 'tc-fits is behind another queued job (not_my_turn' "$SCRATCH/ensure2.log")"

echo "--- launch flags: the offline plan surface carries the VRAM-headroom flag ---"
# ComfyUI sizes its OWN VRAM budget from the free memory it sees, so an EMPTY
# card makes it over-commit and OOM instead of offloading (measured 2026-09-22
# 00:05Z: 21719 MB budget -> torch OOM 78 MiB short on a 23.52 GiB device -> the
# retry then drew "ComfyUI API error: HTTP 500"). --reserve-vram is the fix and
# it must be visible on the surface that needs no GPU and no claim, so a launch
# line that silently drops it fails HERE rather than at the next render.
PLAN="$("$APP_DIR/bin/comfyui_harness.sh" plan 18939 2>/dev/null)"
is "plan exposes the launch args" "1" "$(printf '%s' "$PLAN" | grep -cF -- '--reserve-vram 5')"
is "plan still answers the fit question" "1" "$(printf '%s' "$PLAN" | grep -cF -- 'ask=17GiB')"
is "reserve is overridable" "1" \
   "$(COMFY_RESERVE_VRAM=9 "$APP_DIR/bin/comfyui_harness.sh" plan 18939 2>/dev/null | grep -cF -- '--reserve-vram 9')"

echo
if [ "$FAILED" = 0 ]; then echo "RESULT: ALL PASS"; else echo "RESULT: FAILURES"; fi
exit "$FAILED"
