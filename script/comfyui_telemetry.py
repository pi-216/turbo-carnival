#!/usr/bin/env python3
"""ComfyUI launch telemetry — cgroup memory, OOM attribution, GPU VRAM.

Usage:
  comfyui_telemetry.py --pid PID --job JOB [--out PATH] [--interval 30]

Runs until PID exits. Every --interval seconds it appends one JSON object
(JSONL) to --out describing that moment:

  ts, pid, alive, cgroup, mem_current_mb, mem_peak_mb,
  oom_events, oom_kill_events, vram_used_mib

Why this exists: ComfyUI was being SIGKILLed by the kernel cgroup OOM killer
~25 s into Flux model load because it inherited the 4 GiB Hermes cron worker
scope. Neither the harness nor ComfyUI's own log recorded that — the only
evidence lived in `journalctl -k`, and it aged out. This sampler runs in its
OWN cgroup (launch it via systemd-run) so it survives the death it is
watching, and it reads the victim cgroup's memory.events counters directly.

The final record has "exited": true and the last known memory.peak / oom
counters, which is the definitive OOM attribution.
"""
import argparse
import json
import os
import subprocess
import sys
import time

CGROUP_ROOT = "/sys/fs/cgroup"


def read(path):
    try:
        with open(path) as fh:
            return fh.read().strip()
    except OSError:
        return None


def pid_cgroup(pid):
    """cgroup v2 path (unified hierarchy) for pid, or None if gone."""
    raw = read(f"/proc/{pid}/cgroup")
    if not raw:
        return None
    for line in raw.splitlines():
        parts = line.split(":", 2)
        if len(parts) == 3 and parts[0] == "0":
            return parts[2]
    return None


def mem_bytes(cg, name):
    v = read(os.path.join(CGROUP_ROOT, cg.lstrip("/"), name))
    if v is None:
        return None
    try:
        return int(v)
    except ValueError:
        return None


def events(cg, key):
    raw = read(os.path.join(CGROUP_ROOT, cg.lstrip("/"), "memory.events"))
    if not raw:
        return None
    for line in raw.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0] == key:
            try:
                return int(parts[1])
            except ValueError:
                return None
    return None


def vram_mib():
    try:
        out = subprocess.run(
            ["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=10,
        )
        if out.returncode == 0 and out.stdout.strip():
            return int(out.stdout.strip().splitlines()[0])
    except Exception:
        pass
    return None


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def sample(pid, cached_cg=None):
    # Fall back to the last known cgroup path: once the pid is gone (or the
    # transient unit is collected) /proc/<pid>/cgroup is unreadable, and without
    # the cache the final record — the one that matters — loses its counters.
    cg = pid_cgroup(pid) or cached_cg
    rec = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "pid": pid,
        "cgroup": cg,
        "vram_used_mib": vram_mib(),
    }
    if cg:
        cur = mem_bytes(cg, "memory.current")
        peak = mem_bytes(cg, "memory.peak")
        rec["mem_current_mb"] = None if cur is None else round(cur / 1048576, 1)
        rec["mem_peak_mb"] = None if peak is None else round(peak / 1048576, 1)
        rec["oom_events"] = events(cg, "oom")
        rec["oom_kill_events"] = events(cg, "oom_kill")
    return rec


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pid", type=int, required=True)
    ap.add_argument("--job", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--interval", type=float, default=30.0)
    args = ap.parse_args()

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)

    # First sample immediately: if the cgroup is the cron scope rather than a
    # comfyui-svc unit, that fact is captured before any OOM can erase it.
    last = None
    cg_cache = None
    with open(args.out, "a") as fh:
        while True:
            is_alive = alive(args.pid)
            rec = sample(args.pid, cg_cache)
            if rec.get("cgroup"):
                cg_cache = rec["cgroup"]
            rec["alive"] = is_alive
            rec["job"] = args.job
            if not is_alive:
                rec["exited"] = True
            last = rec
            fh.write(json.dumps(rec) + "\n")
            fh.flush()
            if not is_alive:
                break
            time.sleep(args.interval)

    # Exit summary on stdout for the launching unit's log.
    print(json.dumps({
        "job": args.job,
        "exited": True,
        "cgroup": last.get("cgroup") if last else None,
        "mem_peak_mb": last.get("mem_peak_mb") if last else None,
        "oom_kill_events": last.get("oom_kill_events") if last else None,
        "vram_used_mib": last.get("vram_used_mib") if last else None,
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())