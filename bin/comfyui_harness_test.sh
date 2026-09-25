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

# --- fixtures for blocker_kind / the in-tick wait decision (jobs-bk) ----------
# `poll` answers not_my_turn whenever ANY queued entry has requested_at <= ours,
# whether that entry is WAITING or RUNNING -- and it cannot tell them apart,
# because it does not need to. WE do: a RUNNING one (the GPU's current_job, whose
# record stays status="queued" for its whole life because claim() never flips it)
# releases within minutes and is worth waiting out, while a STALE one is never
# polled by its owner and must not burn the caller's budget. Separate dir so the
# reconcile fixtures above keep their exact expectations.
python3 - "$SCHED/jobs-bk" "$SCRATCH/state-idle.json" "$SCRATCH/state-running.json" <<'PY'
import json, os, sys
d, idle_path, run_path = sys.argv[1:4]
os.makedirs(d, exist_ok=True)


def w(name, **kw):
    rec = {"id": name[:-5], "project": "turbo-carnival", "gpu": "4090",
           "vram_gb": 21.0, "duration_h": 9.0, "status": "queued",
           "requested_at": "2026-09-25T07:00:28Z", "submitted_by": "test",
           "consecutive_failures": 0}
    rec.update(kw)
    with open(os.path.join(d, name), "w") as f:
        json.dump(rec, f, indent=2)


# The live shape measured 2026-09-25T07:00:2xZ: eidolon requested 5 s before us.
w("bk-me.json")
w("bk-first.json", project="prx-tg-flux-latents-hegre",
  requested_at="2026-09-25T06:00:00Z")
w("bk-other.json", project="prx-tg-eidolon-identity-renderer",
  requested_at="2026-09-25T07:00:23Z")

json.dump({"gpus": {"4090": {"status": "idle", "current_job": None}}}, open(idle_path, "w"))
json.dump({"gpus": {"4090": {"status": "busy", "current_job": "bk-other"}}}, open(run_path, "w"))
PY

# Deterministic state path for the ensure tests below: without it they would read
# the LIVE state.json and their outcome would depend on what the 4090 happens to
# be running at test time.
export TC_SCHED_STATE="$SCRATCH/state-idle.json"

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

echo "--- reserve check: the launch-arg discriminator (no GPU) ---"
# Positive/negative control on comfyui_reserve_ok itself. argv is set with
# `exec -a`, so the string under test is the SAME field production reads
# (/proc/<pid>/cmdline). The dummy argv deliberately does NOT match the
# 'main.py --listen' discovery pattern, so a concurrent cron tick can never
# mistake a dummy for the live ComfyUI.
bash -c 'exec -a "dummy-comfy --reserve-vram 5" sleep 20' & DUMMY_OK=$!
bash -c 'exec -a "dummy-comfy --enable-manager"   sleep 20' & DUMMY_NO=$!
sleep 1
bash -c '
  source '"$APP_DIR"'/bin/comfyui_harness.sh ownqueue >/dev/null 2>&1
  comfyui_reserve_ok '"$DUMMY_OK"' && printf "1" || printf "0"
  comfyui_reserve_ok '"$DUMMY_NO"' && printf "1" || printf "0"
  comfyui_reserve_ok 999999        && printf "1" || printf "0"
' > "$SCRATCH/reserve" 2>/dev/null
kill "$DUMMY_OK" "$DUMMY_NO" 2>/dev/null || true
is "flagged argv=ok / unflagged=missing / dead pid=missing" "100" "$(cat "$SCRATCH/reserve")"

# --- ensure(): a ComfyUI that is UP but was launched WITHOUT --reserve-vram is
# --- never rendered through. Adoption is the hole: `launch_comfyui` adopts an
# --- instance already answering :8188 instead of relaunching, so the launch line
# --- is not ours to choose -- and a co-tenant's un-reserved instance sizes its
# --- budget to the whole card, which is the over-commit that OOMed at 00:05Z.
# --- The refusal must happen BEFORE a claim is requested, so it costs a window
# --- and nothing else.
echo "--- ensure: refuses to render through an instance launched without --reserve-vram ---"
: > "$SCRATCH/sched.calls"
TC_SCHED_JOBS_DIR="$SCHED/jobs4" TC_HARNESS_LOG="$SCRATCH/refuse.log" \
  bash -c '
  source '"$APP_DIR"'/bin/comfyui_harness.sh ownqueue >/dev/null 2>&1
  STATE_FILE="'"$SCRATCH"'/claim3.json"; rm -f "$STATE_FILE"
  vram_free_mib() { echo 21500; }          # 21GiB free: ONLY the missing flag can stop us
  comfyui_up() { return 0; }               # an instance IS answering :8188
  comfyui_ours() { return 1; }             # ... not ours
  comfyui_reserve_ok() { return 1; }       # ... and it lacks --reserve-vram
  comfyui_holder_class() { echo operator; }  # ... and a HUMAN owns it
  gpu_idle() { return 0; }
  sched() { printf "%s\n" "$*" >> "'"$SCRATCH"'/sched.calls"
            case "$1" in poll) echo claimed ;; *) : ;; esac; return 0; }
  cmd_ensure --wait 5; printf "rc=%s" "$?"
' > "$SCRATCH/refuse.out" 2>/dev/null
is "ensure refuses with rc=2" "rc=2" "$(cat "$SCRATCH/refuse.out")"
is "refusal names the reason" "1" "$(grep -c 'REFUSING this tick' "$SCRATCH/refuse.log")"
is "foreign un-reserved instance not adopted" "1" "$(grep -c 'NOT adopting it' "$SCRATCH/refuse.log")"
is "no claim requested (nothing minted, nothing queued)" "0" "$(grep -c 'request --gpu' "$SCRATCH/sched.calls")"
# WHO holds it decides the response: an operator's session is a human's to end, so
# the refusal must SAY so (2026-09-22: the brain tick called the same instance a
# foreign project whose "clean fix" was to relaunch it with flags -- i.e. it
# proposed re-flagging the operator's own tmux session).
is "refusal carries the holder class" "1" "$(grep -c 'holder=operator' "$SCRATCH/refuse.log")"
is "refusal forbids touching the operator's session" "1" \
   "$(grep -c "the OPERATOR's interactive session" "$SCRATCH/refuse.log")"
is "refusal does not propose re-flagging the holder" "0" \
   "$(grep -c 'relaunch their ComfyUI' "$SCRATCH/refuse.log")"

# Same refusal, different holder: the clause must follow the CLASS, not the flag
# situation -- a supervised unit is another project's to change, not ours.
echo "--- ensure: the refusal clause follows the holder class (unit) ---"
TC_SCHED_JOBS_DIR="$SCHED/jobs4" TC_HARNESS_LOG="$SCRATCH/refuse-unit.log" \
  bash -c '
  source '"$APP_DIR"'/bin/comfyui_harness.sh ownqueue >/dev/null 2>&1
  STATE_FILE="'"$SCRATCH"'/claim3b.json"; rm -f "$STATE_FILE"
  vram_free_mib() { echo 21500; }
  comfyui_up() { return 0; }
  comfyui_ours() { return 1; }
  comfyui_reserve_ok() { return 1; }
  comfyui_holder_class() { echo unit; }
  gpu_idle() { return 0; }
  sched() { printf "%s\n" "$*" >> "'"$SCRATCH"'/sched.calls"; return 0; }
  cmd_ensure --wait 5; exit 0
' > /dev/null 2>&1
is "unit holder named as another project's" "1" \
   "$(grep -c "another project's supervised unit" "$SCRATCH/refuse-unit.log")"
is "unit clause is NOT the operator wording" "0" \
   "$(grep -c "OPERATOR's interactive session" "$SCRATCH/refuse-unit.log")"

echo "--- ensure: a flagged instance is still adopted (not a blanket refusal) ---"
: > "$SCRATCH/sched.calls"
TC_SCHED_JOBS_DIR="$SCHED/jobs5" TC_HARNESS_LOG="$SCRATCH/adopt.log" \
  bash -c '
  source '"$APP_DIR"'/bin/comfyui_harness.sh ownqueue >/dev/null 2>&1
  STATE_FILE="'"$SCRATCH"'/claim4.json"; rm -f "$STATE_FILE"
  vram_free_mib() { echo 21500; }
  comfyui_up() { return 0; }
  comfyui_ours() { return 1; }
  comfyui_reserve_ok() { return 0; }       # the running instance carries the flag
  gpu_idle() { return 0; }
  sched() { printf "%s\n" "$*" >> "'"$SCRATCH"'/sched.calls"
            case "$1" in poll) echo not_my_turn ;; *) : ;; esac; return 0; }
  cmd_ensure --wait 5; exit 0
' > "$SCRATCH/adopt.out" 2>/dev/null
is "flagged instance is NOT refused" "0" "$(grep -c 'REFUSING this tick' "$SCRATCH/adopt.log")"
is "claim requested at the live-fit ask" "1" "$(grep -c 'request --gpu 4090 --project turbo-carnival --vram 19 ' "$SCRATCH/sched.calls")"

echo "--- status: the refusal condition is visible to monitors ---"
if grep -q 'comfyui=up' "$SCRATCH/status.out"; then
  is "status carries reserve=<ok|missing>" "1" \
     "$(grep -cE 'comfyui=up.*reserve=(ok|missing)' "$SCRATCH/status.out")"
  # holder= is what turns `owner=foreign` into a WHO: without it a monitor has to
  # hand-read /proc to learn whether the blocker is a human's session (yield) or
  # another project's unit (policy), which cost three consecutive triage passes.
  is "status carries holder=<class>" "1" \
     "$(grep -cE 'comfyui=up.*holder=(operator|agent|unit|other|unknown)' "$SCRATCH/status.out")"
else
  printf '  SKIP  nothing answering :8188 at test time (%s)\n' "$(cat "$SCRATCH/status.out")"
fi

echo "--- kill: only an instance WE launched is ours to stop ---"
# The close path (tick-end `shutdown`) used to `pgrep -f 'main\.py --listen'` and
# SIGTERM (then SIGKILL) EVERY match. It runs right after an ADOPTED foreign
# instance -- so the response the board itself recommends to the launch-args
# refusal ("relaunch with --reserve-vram, the harness adopts it") armed a kill of
# the operator's own tmux session at the end of our next tick. Ownership is now
# the RECORDED pid PLUS origin=launched, enforced in kill_comfyui itself.
export TC_CLAIM_FILE="$SCRATCH/claim.json"
setsid bash -c 'exec -a "python main.py --listen 0.0.0.0" sleep 300' &
DECOY=$!
sleep 1
if ! tr '\0' ' ' < "/proc/$DECOY/cmdline" 2>/dev/null | grep -q 'main.py --listen'; then
  printf '  SKIP  could not stage a decoy matching the discovery pattern\n'
else
  write_claim() {
    printf '{"job_id": "", "heartbeat_pid": "", "comfy_pid": "%s", "origin": "%s"}\n' "$1" "$2" > "$TC_CLAIM_FILE"
  }
  close_path() {
    bash -c 'source '"$APP_DIR"'/bin/comfyui_harness.sh killverdict launched 1 live >/dev/null 2>&1; kill_comfyui' \
      >> "$SCRATCH/kill.log" 2>&1
  }
  alive() { kill -0 "$1" 2>/dev/null && echo yes || echo no; }

  write_claim "$DECOY" adopted
  close_path
  is "ADOPTED (foreign) instance survives the close path" "yes" "$(alive "$DECOY")"
  is "the refusal to kill is logged with the reason" "1" \
     "$(grep -c 'NOT killed — pid .* was ADOPTED' "$SCRATCH/kill.log")"

  rm -f "$TC_CLAIM_FILE"
  close_path
  is "no recorded pid -> nothing killed" "yes" "$(alive "$DECOY")"

  write_claim "$DECOY" launched
  close_path
  sleep 1
  is "our OWN instance (origin=launched) is stopped" "no" "$(alive "$DECOY")"

  kill -9 "$DECOY" 2>/dev/null
fi

echo "--- shutdown: the queue-first guard is CLAIM-conditional ---"
# Measured 2026-09-23 10:04:16: the guard fired with NO claim in the state file (the
# operator's foreign instance was mid-render) and logged "keeping claim  alive so they
# drain" -- an empty job id and a claim that did not exist -- then returned 3 for a tick
# that had nothing to refuse. Only a CLAIM is worth keeping: with none there is nothing
# of ours to protect and nothing of ours to stop, so it must say so and carry on down the
# normal path. (The ownership rule that stops kill_comfyui touching a foreign instance is
# covered above; here kill_comfyui is stubbed so this test can never signal a pid.)
run_shutdown() { # run_shutdown <tag> <claim?yes|no> <queue_empty?yes|no>
  : > "$SCRATCH/sd-kill"; : > "$SCRATCH/sd-sched"; : > "$SCRATCH/sd-systemctl"
  TC_HARNESS_LOG="$SCRATCH/sd-$1.log" \
  bash -c '
    source '"$APP_DIR"'/bin/comfyui_harness.sh ownqueue >/dev/null 2>&1
    claim="'"$2"'"; qempty="'"$3"'"
    read_state() {
      if [ "$claim" = yes ]; then printf "%s\n" "comfyui-testjob-1" "" "424242" "launched";
      else printf "%s\n" "" "" "" ""; fi
    }
    comfyui_up() { return 0; }
    comfyui_queue_empty() { [ "$qempty" = yes ]; return $?; }
    hb_alive() { return 1; }
    comfy_unit() { echo test-unit; }
    stop_heartbeat() { :; }
    kill_comfyui() { printf "KILL\n" >> '"$SCRATCH"'/sd-kill; }
    sched() { printf "%s\n" "$*" >> '"$SCRATCH"'/sd-sched; }
    systemctl() { printf "%s\n" "$*" >> '"$SCRATCH"'/sd-systemctl; }
    vram_mib() { echo 612; }
    gpu_idle() { return 1; }
    TELE_FILE=""
    STATE_FILE="'"$SCRATCH"'/sd-claim-'"$1"'"; rm -f "$STATE_FILE"
    rc=0; cmd_shutdown || rc=$?; printf "rc=%s" "$rc"
  ' > "$SCRATCH/sd-$1.out" 2>/dev/null
}

run_shutdown no-claim no no
is "no claim + busy queue: continues (rc=0)" "rc=0" "$(cat "$SCRATCH/sd-no-claim.out")"
is "no claim + busy queue: says THIS TICK HOLDS NO CLAIM" "1" \
   "$(grep -c 'HOLDS NO CLAIM' "$SCRATCH/sd-no-claim.log")"
is "no claim + busy queue: never claims to keep a claim" "0" \
   "$(grep -c 'keeping claim' "$SCRATCH/sd-no-claim.log")"
is "no claim + busy queue: reaches the no-claim path" "1" \
   "$(grep -c 'no claim in state file' "$SCRATCH/sd-no-claim.log")"
is "no claim + busy queue: touches no systemd unit" "0" "$(grep -c 'stop' "$SCRATCH/sd-systemctl")"

run_shutdown claim-busy yes no
is "claim + busy queue: still refuses (rc=3)" "rc=3" "$(cat "$SCRATCH/sd-claim-busy.out")"
is "claim + busy queue: names the claim it keeps" "1" \
   "$(grep -c 'keeping claim comfyui-testjob-1 alive' "$SCRATCH/sd-claim-busy.log")"
is "claim + busy queue: kills nothing" "0" "$(grep -c 'KILL' "$SCRATCH/sd-kill")"
is "claim + busy queue: releases nothing" "0" "$(grep -c 'release' "$SCRATCH/sd-sched")"

run_shutdown claim-empty yes yes
is "claim + empty queue: proceeds (rc=0)" "rc=0" "$(cat "$SCRATCH/sd-claim-empty.out")"
is "claim + empty queue: stops the instance" "1" "$(grep -c 'KILL' "$SCRATCH/sd-kill")"
is "claim + empty queue: releases the claim" "1" "$(grep -c 'release --gpu' "$SCRATCH/sd-sched")"

echo "--- blocker_kind: a RUNNING job ahead is worth waiting for, a STALE one is not ---"
# blockerkind is a pure file read (jobs dir + state.json), so it is answerable with
# no GPU, no claim and no scheduler call.
bk() { TC_SCHED_JOBS_DIR="$SCHED/jobs-bk" TC_SCHED_STATE="$1" \
       bash "$APP_DIR/bin/comfyui_harness.sh" blockerkind "$2" 2>/dev/null; }
is "a RUNNING job ahead of us -> running" "running" "$(bk "$SCRATCH/state-running.json" bk-me)"
is "a queued entry ahead of us that is NOT running -> stale" "stale" "$(bk "$SCRATCH/state-idle.json" bk-me)"
is "nothing ahead of this entry -> none" "none" "$(bk "$SCRATCH/state-idle.json" bk-first)"
# An unreadable state file must NOT produce a wait: "stale" is the give-up answer,
# so a state.json that cannot be read costs a refused tick, never a stalled one.
is "unreadable state file -> stale (never a wait)" "stale" \
   "$(bk "$SCRATCH/state-does-not-exist.json" bk-me)"

# The in-tick wait decision, exercised end to end against a stubbed `poll` that
# always answers not_my_turn -- the caller's whole budget is at stake, so the two
# shapes must not be confused:
#   RUNNING -> keep re-polling until the stubbed deadline (the blocker will release)
#   STALE   -> return 2 at once (nothing will release it; 2026-09-21 refused every
#              tick from 09:01 to 22:34 and waiting would have burned all 13 hours)
run_ensure_nmy() { # run_ensure_nmy <tag> <state.json> <deadline_s>
  : > "$SCRATCH/nmy-$1.calls"
  TC_SCHED_JOBS_DIR="$SCHED/jobs-bk" TC_HARNESS_LOG="$SCRATCH/nmy-$1.log" \
  TC_SCHED_STATE="$2" TC_ENSURE_DEADLINE="$3" TC_POLL_INTERVAL=1 \
  bash -c '
    source '"$APP_DIR"'/bin/comfyui_harness.sh ownqueue >/dev/null 2>&1
    STATE_FILE="'$SCRATCH'/nmy-claim-'"$1"'.json"; rm -f "$STATE_FILE"
    # 23500 MiB free -> the live-fit ask is the full 21GiB, so the adopted fixture
    # entry (vram_gb 21.0) is KEPT instead of retired for asking above the live fit
    # -- this test is about the FIFO wait, not about the ask policy (covered above).
    vram_free_mib() { echo 23500; }
    comfyui_up() { return 1; }
    gpu_idle() { return 0; }
    comfyui_running_pid() { echo ""; }
    comfyui_ours() { return 1; }
    sched() { case "$1" in
                poll) printf "poll\n" >> "'$SCRATCH'/nmy-'"$1"'.calls"; echo not_my_turn ;;
                status) printf "4090:\n  status:     idle\n  current_job: None\n" ;;
                request) printf "request\n" >> "'$SCRATCH'/nmy-'"$1"'.calls" ;;
                *) : ;;
              esac; return 0; }
    rc=0; cmd_ensure --wait 5 || rc=$?; printf "rc=%s" "$rc"
  ' > "$SCRATCH/nmy-$1.out" 2>/dev/null
}

run_ensure_nmy stale "$SCRATCH/state-idle.json" 360
is "STALE blocker: refused this tick (rc=2)" "rc=2" "$(cat "$SCRATCH/nmy-stale.out")"
is "STALE blocker: named as not-running" "1" "$(grep -c 'blocker=stale' "$SCRATCH/nmy-stale.log")"
is "STALE blocker: polled exactly once (no budget burned)" "1" "$(grep -c poll "$SCRATCH/nmy-stale.calls")"
is "STALE blocker: our FIFO place is KEPT" "queued" "$(field "$SCHED/jobs-bk/bk-me.json" status)"
is "STALE blocker: never asks for a second entry" "0" "$(grep -c request "$SCRATCH/nmy-stale.calls")"

run_ensure_nmy running "$SCRATCH/state-running.json" 4
is "RUNNING blocker: still refuses when it does not release in time (rc=2)" "rc=2" \
   "$(cat "$SCRATCH/nmy-running.out")"
is "RUNNING blocker: waited and re-polled (>=3 polls)" "1" \
   "$([ "$(grep -c poll "$SCRATCH/nmy-running.calls")" -ge 3 ] && echo 1 || echo 0)"
is "RUNNING blocker: logs the wait, with the deadline" "1" \
   "$(grep -c 'waiting it out' "$SCRATCH/nmy-running.log")"
is "RUNNING blocker: refusal names the kind, not a generic queued job" "1" \
   "$(grep -c 'blocker=running' "$SCRATCH/nmy-running.log")"
is "RUNNING blocker: our FIFO place is KEPT" "queued" "$(field "$SCHED/jobs-bk/bk-me.json" status)"

echo
if [ "$FAILED" = 0 ]; then echo "RESULT: ALL PASS"; else echo "RESULT: FAILURES"; fi
exit "$FAILED"
