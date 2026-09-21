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

echo
if [ "$FAILED" = 0 ]; then echo "RESULT: ALL PASS"; else echo "RESULT: FAILURES"; fi
exit "$FAILED"
