#!/bin/bash
# =============================================================================
# phase_handoff_test.sh — mechanism test for bin/phase_handoff.sh (ticket #25).
#
# No GPU, no scheduler, no claim, no DB. A FAKE `nvidia-smi` on PATH supplies a
# scripted free-MiB reading and FAKE tenant harnesses supply a scripted `status`
# / `stop-server`, so every branch of the measured-VRAM gate is exercised — and
# the refusal is proved by EXIT CODE, not by reading the script.
#
# The four assertions that matter, and the failure each one catches:
#   1. residency beats a reading — a resident outgoing tenant parks the handoff
#      even when the free-MiB number happens to clear the floor; a gate that
#      checked free VRAM alone would start the second tenant on a busy card.
#   2. a foreign tenant is never stopped — the handoff parks instead of killing
#      it; a gate that stopped anything it found would kill a co-tenant's server.
#   3. proceed is earned by a DEVICE reading that clears the floor — the poll
#      advances only when `nvidia-smi` says so, not when stop-server returns 0.
#   4. stop success is not freed memory — stop-server exiting 0 while the device
#      still reports low free VRAM must PARK (the CUDA-holds-VRAM red line).
#
# Usage: bin/phase_handoff_test.sh            (exit 0 = all assertions pass)
# =============================================================================
set -u

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$APP_DIR/bin/phase_handoff.sh"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/phase-handoff-test.XXXXXX")"
FAILED=0

ok() {  # ok <name> <actual> <expected>
  if [ "$2" = "$3" ]; then
    echo "  PASS $1"
  else
    echo "  FAIL $1: got [$2] want [$3]"
    FAILED=$((FAILED + 1))
  fi
}

# --- fixtures ---------------------------------------------------------------
mkdir -p "$SCRATCH/bin"

# Fake nvidia-smi: prints the first line of free_seq and pops it; when the
# sequence is empty it repeats the last value in free_hold (default 0).
cat > "$SCRATCH/bin/nvidia-smi" <<'SH'
#!/bin/bash
seq_file="$PH_SCRATCH/free_seq"
hold_file="$PH_SCRATCH/free_hold"
if [ -s "$seq_file" ]; then
  head -1 "$seq_file"
  tail -n +2 "$seq_file" > "$seq_file.tmp" && mv "$seq_file.tmp" "$seq_file"
else
  cat "$hold_file" 2>/dev/null || echo 0
fi
SH
chmod +x "$SCRATCH/bin/nvidia-smi"

# Fake tenant harness. `status` prints the scripted line; `stop-server` records
# the call and exits with the scripted rc (proving rc is NOT used as evidence).
cat > "$SCRATCH/bin/fake_harness" <<'SH'
#!/bin/bash
name="$PH_TENANT"
case "${1:-}" in
  status)
    up="$(cat "$PH_SCRATCH/${name}_state" 2>/dev/null || echo down)"
    ours="$(cat "$PH_SCRATCH/${name}_ours" 2>/dev/null || echo yes)"
    echo "claim=busy job=test-1 ours=${ours} ${name}=${up}"
    ;;
  stop-server)
    touch "$PH_SCRATCH/${name}_stop_called"
    rc="$(cat "$PH_SCRATCH/${name}_stop_rc" 2>/dev/null || echo 0)"
    # A real stop-server closes the port, so `status` reports down. The state is
    # flipped only on success; a nonzero rc leaves it resident (fail-closed).
    [ "$rc" = "0" ] && printf 'down\n' > "$PH_SCRATCH/${name}_state"
    echo "fake stop-server ${name}"
    exit "$rc"
    ;;
esac
SH
chmod +x "$SCRATCH/bin/fake_harness"

export PH_SCRATCH="$SCRATCH"
export PATH="$SCRATCH/bin:$PATH"
# Point the gate at the fake harnesses via its documented env hooks.
export TC_BRAIN_HARNESS="$SCRATCH/bin/fake_harness"
export TC_COMFYUI_HARNESS="$SCRATCH/bin/fake_harness"
export PH_TENANT=brain
export TC_HANDOFF_POLL=1
export TC_HANDOFF_LOG="$SCRATCH/handoff.log"

run() {  # run <cmd...>; echoes exit code
  "$@" >/dev/null 2>&1
  echo $?
}

set_free() { printf '%s\n' "$@" > "$SCRATCH/free_seq"; printf '%s\n' "${1:-0}" > "$SCRATCH/free_hold"; }
set_state() { printf '%s\n' "$2" > "$SCRATCH/${1}_state"; }
set_ours()  { printf '%s\n' "$2" > "$SCRATCH/${1}_ours"; }
set_stop_rc() { printf '%s\n' "$2" > "$SCRATCH/${1}_stop_rc"; }

echo "phase_handoff_test — $GATE"

# --- 1. pure verdict (no GPU, no harness) -----------------------------------
echo "pure verdict (plan):"
ok "proceed when free clears the floor" \
   "$(run "$GATE" plan 20000 16 down)" 0
ok "park when free is below the floor" \
   "$(run "$GATE" plan 10000 16 down)" 3
ok "residency beats a high reading" \
   "$(run "$GATE" plan 99999 16 up)" 3
ok "unreadable device parks" \
   "$(run "$GATE" plan '' 16 down)" 4

# --- 2. measure reads the DEVICE --------------------------------------------
echo "measure (device read):"
set_free 20000
ok "measure proceeds on a cleared reading" "$(run "$GATE" measure --floor 16)" 0
set_free 10000
ok "measure parks on a low reading"        "$(run "$GATE" measure --floor 16)" 3
printf '' > "$SCRATCH/free_seq"; printf '' > "$SCRATCH/free_hold"
ok "measure parks when the device is unreadable" "$(run "$GATE" measure --floor 16)" 4

# --- 3. check render: residency is the gate ---------------------------------
echo "check render (read-only):"
set_free 30000                       # plenty free ...
set_state brain up                   # ... but the brain is still resident
ok "check parks while the brain is resident" "$(run "$GATE" check render --floor 16)" 3
set_state brain down
set_free 30000
ok "check admits the render phase once the brain is down and free clears" \
   "$(run "$GATE" check render --floor 16)" 0

# --- 4. to-render: foreign tenant is never stopped --------------------------
echo "to-render (foreign tenant):"
set_free 30000
set_state brain up
set_ours brain no
rm -f "$SCRATCH/brain_stop_called"
ok "a foreign resident brain parks the handoff" \
   "$(TC_HANDOFF_WAIT=0 "$GATE" to-render --floor 16 >/dev/null 2>&1; echo $?)" 3
if [ -f "$SCRATCH/brain_stop_called" ]; then
  echo "  FAIL foreign tenant was stopped"; FAILED=$((FAILED + 1))
else
  echo "  PASS foreign tenant never stopped"
fi

# --- 5. to-render: proceed earned by the DEVICE reading ---------------------
echo "to-render (measured freedom):"
set_state brain up
set_ours brain yes
set_stop_rc brain 0
# First reading is CUDA still holding VRAM; the second clears the floor.
set_free 12000 20000
rm -f "$SCRATCH/brain_stop_called"
ok "proceeds only after the measured reading clears the floor" \
   "$(TC_HANDOFF_WAIT=10 "$GATE" to-render --floor 16 >/dev/null 2>&1; echo $?)" 0
[ -f "$SCRATCH/brain_stop_called" ] && echo "  PASS our brain was stopped" \
  || { echo "  FAIL our brain was not stopped"; FAILED=$((FAILED + 1)); }

# --- 6. the red line: stop success is not freed memory ----------------------
echo "to-render (stop rc is not evidence):"
set_state brain up                 # our brain is resident, and stop will SUCCEED ...
set_ours brain yes
set_stop_rc brain 0
set_free 10000 10000 10000 10000   # ... but the device never frees (CUDA holds VRAM)
ok "parks even though stop-server returned 0" \
   "$(TC_HANDOFF_WAIT=0 "$GATE" to-render --floor 16 >/dev/null 2>&1; echo $?)" 3

echo
if [ "$FAILED" -eq 0 ]; then
  echo "OK — all phase_handoff assertions passed"
  exit 0
fi
echo "FAILED — $FAILED assertion(s)"
exit 1
