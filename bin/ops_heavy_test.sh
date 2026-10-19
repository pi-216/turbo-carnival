#!/bin/bash
# =============================================================================
# ops_heavy_test.sh — mechanism test for bin/ops_heavy.sh's OUTPUT-CAPTURE
# contract. No GPU, no scheduler, no DB; every case runs a trivial command in a
# throwaway scope, so it is safe to run at any time, including from a cron tick.
#
# Why this test exists (2026-09-25): the runner used to send the child's output
# to /dev/null, so any heavy command whose TEXT is the point (a gate read, an
# inventory count) could not be isolated — the tick had to run it inline, which
# is exactly what gets the tick OOM-killed at the 4 GiB worker cap. The capture
# is now a contract: the child writes to $OPS_HEAVY_OUT, the last $OPS_HEAVY_TAIL
# lines and the path are echoed, the verdict line still carries rc/peak/cap/oom
# and the isolation assertion, and the child's exit code is propagated.
#
# The three assertions that matter, and the failure each one catches:
#   1. capture+rc    — output silently discarded again, or rc swallowed by the
#                      added post-processing (a caller would read "success").
#   2. silent case   — a "output ->" line printed for a command that produced
#                      nothing, which would make the path unusable as evidence.
#   3. usage         — no-arg invocation must fail loudly (rc 2), never run.
#
# NOTE: deliberately contains NO deletion primitive (no rm), so it can run
# unattended; the scratch dir is created under $TMPDIR and left to the pruner.
# Usage: bin/ops_heavy_test.sh            (exit 0 = all assertions pass)
# =============================================================================
set -u

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/ops-heavy-test.XXXXXX")"
RUNNER="$APP_DIR/bin/ops_heavy.sh"
FAILED=0

ok() {  # ok <name> <actual> <expected>
  if [ "$2" = "$3" ]; then
    echo "  PASS $1"
  else
    echo "  FAIL $1: got [$2] want [$3]"
    FAILED=$((FAILED + 1))
  fi
}

ok_contains() {  # ok_contains <name> <haystack> <needle>
  case "$2" in
    *"$3"*) echo "  PASS $1" ;;
    *)      echo "  FAIL $1: [$3] not found in output"; FAILED=$((FAILED + 1)) ;;
  esac
}

ok_absent() {  # ok_absent <name> <haystack> <needle>
  case "$2" in
    *"$3"*) echo "  FAIL $1: [$3] unexpectedly present"; FAILED=$((FAILED + 1)) ;;
    *)      echo "  PASS $1" ;;
  esac
}

echo "ops_heavy_test: runner=$RUNNER scratch=$SCRATCH"

# --- 1. capture + exit-code propagation --------------------------------------
out1="$SCRATCH/capture.out"
got1="$(OPS_HEAVY_OUT="$out1" "$RUNNER" t-capture \
        bash -c 'echo out-line; echo err-line >&2; exit 3' 2>&1)"; rc1=$?
ok "capture[rc propagated]" "$rc1" "3"
ok_contains "capture[verdict line]" "$got1" "label=t-capture rc=3"
ok_contains "capture[isolation asserted]" "$got1" "isolated=yes"
ok_contains "capture[peak reported]" "$got1" "peak_mb="
ok_contains "capture[path echoed]" "$got1" "output -> $out1"
file1="$(cat "$out1" 2>/dev/null || echo '(unreadable)')"
ok_contains "capture[stdout landed]" "$file1" "out-line"
ok_contains "capture[stderr landed]" "$file1" "err-line"

# --- 2. a silent command must not advertise an output path -------------------
out2="$SCRATCH/quiet.out"
got2="$(OPS_HEAVY_OUT="$out2" "$RUNNER" t-quiet true 2>&1)"; rc2=$?
ok "quiet[rc propagated]" "$rc2" "0"
ok_contains "quiet[verdict line]" "$got2" "label=t-quiet rc=0"
ok_absent "quiet[no output line]" "$got2" "output ->"

# --- 3. no args: loud usage, nothing run -------------------------------------
got3="$("$RUNNER" 2>&1)"; rc3=$?
ok "usage[rc]" "$rc3" "2"
ok_contains "usage[message]" "$got3" "usage: bin/ops_heavy.sh"

if [ "$FAILED" -eq 0 ]; then
  echo "ops_heavy_test: ALL PASS"
  exit 0
fi
echo "ops_heavy_test: $FAILED failure(s)"
exit 1
