#!/bin/bash
# ops_heavy.sh <label> <command...>
#
# WHY THIS EXISTS (measured 2026-09-24, do not "simplify" it away)
# ---------------------------------------------------------------
# A Hermes cron worker runs in its OWN transient cgroup scope with
# `MemoryMax=4 GiB` (min(gateway memory.max, RAM/2) bounded to 4 GiB). Anything a
# tick spawns inherits that scope -- setsid/nohup do not escape a cgroup -- so a
# memory-heavy VERIFICATION command run inline kills the whole tick:
#
#   2026-09-24 13:40:34Z  oom_memcg=.../hermes-worker-cron-9c05f60f5fef-exec-0889....scope
#                         4.13 GB anon against a 4096 MB cap, failcnt 31149
#                         Killed process 1254158 (node-MainThread)
#                         Killed process 1265063 (ruby)
#   -> the ops-triage tick died mid-verification, its execution row ended
#      `unknown`, NO report was delivered, and the pass was silently lost.
#      18 such kills in the 7 days to 2026-09-24 (14 of them the growth-brain on
#      09-18, hourly) -- all of them our own cron workers.
#
# The commands that do it (measured in an isolated scope, `bin/rubocop` 1.81.7):
#   bin/rubocop -f simple        peak 3518 MB / 2113 MB, up to 38 processes
#   bin/rubocop -f simple  app/models/gap_analysis.rb    peak 91 MB, 1 process
# RuboCop 1.81 defaults to `--parallel` across ALL CPUs (its own --help: "Default
# is true"), so a full-repo run forks ~32 workers that each hold a slice of the
# tree; even `PARALLEL_PROCESSOR_COUNT=4` still peaked at 2279 MB. A full-repo
# lint therefore needs more than HALF the worker's entire memory budget, and the
# tick that ran it was killed. `python3 bin/tc_ops.py probe` (the always-on path)
# peaks at only 203 MB and is safe inline.
#
# HOW IT FIXES IT
# ---------------
# Run heavy verification in its OWN systemd user scope, outside the worker's cap,
# with accounting so the cost is measured rather than guessed. The child's cgroup
# is asserted after launch: PID adjacency is not proof of isolation, the cgroup
# path is.
#
#   bin/ops_heavy.sh rubocop bin/rubocop -f simple
#   bin/ops_heavy.sh rspec   bundle exec rspec
#
# Prints: rc=<code> peak_mb=<scope peak> cap_mb=<scope cap> oom_kill=<0|n> and
# the scope path, so a tick can record what the command actually cost.
#
# The command's OUTPUT is captured, not discarded (2026-09-25). It used to go to
# /dev/null, which meant any heavy command whose output is the point -- a gate
# read, an inventory count, a report -- could NOT be isolated: the tick had to
# run it inline (the very thing that gets the tick OOM-killed) or lose the text.
# Now the child writes to $OPS_HEAVY_OUT (default log/ops_heavy-<label>.out) and
# the last $OPS_HEAVY_TAIL (default 25) lines are echoed after the verdict, with
# the path for the full text. Bounded on purpose: an unbounded dump would flood
# the tick's context instead of the caller's memory.
# Fallback when systemd-run is unavailable: run inline and WARN that the caller's
# cgroup applies (an honest loud failure, never a silent one).
set -u

label="${1:-}"; shift || true
if [ -z "$label" ] || [ "$#" -eq 0 ]; then
  echo "usage: bin/ops_heavy.sh <label> <command...>" >&2
  exit 2
fi
cd "$(dirname "$0")/.." || exit 1

mem_max="${OPS_HEAVY_MEM_MAX:-8G}"

# systemd-run --user --scope: the command becomes the scope's main process.
# MemoryAccounting so peak/oom are readable; the cap protects the box (and the
# shared GPU work) from a runaway -- unlike ComfyUI, lint/test runners do not
# size their caches from the cgroup limit, so a cap cannot mislead them.
if ! command -v systemd-run >/dev/null 2>&1; then
  echo "ops_heavy: WARN systemd-run unavailable -- running INLINE in this worker's" \
       "cgroup, so a MemoryMax on the caller still applies." >&2
  "$@"
  rc=$?
  echo "ops_heavy: label=$label rc=$rc isolated=no"
  exit "$rc"
fi

unit="ops-heavy-$label-$$"
# Output capture: the child writes here so a heavy command whose TEXT is the
# point can still be isolated (see the header). Absolute path, because the
# child's cwd is the scope's, and exported so the inner bash can see it.
out="${OPS_HEAVY_OUT:-$PWD/log/ops_heavy-$label.out}"
mkdir -p "$(dirname "$out")" 2>/dev/null || true
export OPS_HEAVY_OUT_FILE="$out"
: > "$out" 2>/dev/null || true

systemd-run --user --scope --unit="$unit" -q --collect \
  -p MemoryAccounting=yes -p MemoryMax="$mem_max" \
  bash -c '
    cg=/sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)
    # Isolation assertion: the cgroup path IS the discriminator. If the command
    # did not land in our dedicated scope, say so loudly -- a command that only
    # LOOKS isolated will be OOM-killed with the tick.
    case "$cg" in
      *ops-heavy-*) iso=yes ;;
      *)            iso=no
                    echo "ops_heavy: ERROR child cgroup is $cg, not a dedicated" \
                         "ops-heavy scope -- isolation did NOT apply, this runs" \
                         "under the callers own cap." >&2 ;;
    esac
    timeout "${OPS_HEAVY_TIMEOUT:-900}" "$@" > "${OPS_HEAVY_OUT_FILE:-/dev/null}" 2>&1; rc=$?
    peak=$(( $(cat "$cg/memory.peak" 2>/dev/null || echo 0) / 1048576 ))
    cap=$(( $(cat "$cg/memory.max" 2>/dev/null || echo 0) / 1048576 ))
    oom=$(grep -o "[0-9]*$" <(grep "^oom_kill " "$cg/memory.events" 2>/dev/null) || echo 0)
    echo "ops_heavy: label='"$label"' rc=$rc peak_mb=$peak cap_mb=$cap oom_kill=${oom:-0} isolated=$iso cgroup=$cg"
    exit $rc
  ' _ "$@"
rc=$?

# Surface the capture, bounded: the last OPS_HEAVY_TAIL lines plus the path to
# the full text. Silence when the command produced nothing (a pure lint pass).
if [ -s "$out" ]; then
  echo "ops_heavy: output -> $out (last ${OPS_HEAVY_TAIL:-25} line(s) below)"
  tail -n "${OPS_HEAVY_TAIL:-25}" "$out"
fi
exit "$rc"