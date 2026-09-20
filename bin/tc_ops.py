#!/usr/bin/env python3
"""tc_ops — turbo-carnival ops board: probe signals, file issues, work them.

The problem this solves: monitoring existed (cron jobs, harness logs, telemetry)
but nothing turned a detected problem into a tracked, closable work item, so the
same failures got re-diagnosed from scratch and tech debt accumulated silently.

Design: a file-based board (no server, no Jira dependency). One JSON file per
issue under ops/board/, keyed by a STABLE key, so repeated probes refresh the
same issue instead of creating duplicates. An agent-driven cron runs `probe`,
then works the open issues and closes them with a note.

  tc_ops.py probe            scan signals, file/refresh issues, print summary
  tc_ops.py list [--all]     list issues (open by default)
  tc_ops.py show KEY         full issue record
  tc_ops.py close KEY [-n]   close an issue with a resolution note
  tc_ops.py touch KEY        bump an issue (used by fixers to record progress)

Probe exits 0 always (cron-safe); prints CRITICAL/WARN counts.
"""
from __future__ import annotations

import json
import calendar
import os
import re
import subprocess
import sys
import time
from pathlib import Path

APP = Path(__file__).resolve().parent.parent
BOARD = APP / "ops" / "board"
SCHED_DIR = Path("/mnt/nas-ai-models/gpu-scheduler")
HARNESS_LOG = APP / "log" / "comfyui_harness.log"
TELE_FILE = APP / "log" / "comfyui_telemetry.jsonl"
CLAIM_FILE = APP / "log" / "comfyui_claim.json"
COMFY_DIR = Path("/mnt/fscache/essdee/ComfyUI")
DB = "turbo_carnival_development"
GPU = "4090"

SEV_ORDER = {"critical": 3, "warn": 2, "info": 1}

# A foreign project holding the 4090 is the NORMAL shared-resource state (our rules
# forbid interfering), so it is only worth an issue once the hold is long enough to
# starve our renders. Below this, filing it is board churn, not signal.
FOREIGN_HOLD_ALERT_H = 6.0
# Starvation = we asked for the GPU and were refused, AND nothing came out.
STARVE_WINDOW_H = 12
# Placeholder-caption rate: a single fallback is a cold-load blip, a sustained
# rate means the caption path is dead and every post ships 'Fresh look'.
CAPTION_MIN_POSTS = 3
CAPTION_ALERT_RATIO = 0.3
# Publisher liveness (bin/scheduled_posting.sh, hourly from the user crontab):
# its worst case delay is one tick, so 3h absorbs a single missed run.
PUBLISH_GRACE_H = 3
PUBLISH_CRITICAL_H = 12
# Board notes are a rolling window: keep the newest N per issue, archive the rest.
NOTE_KEEP = 6
# An up ComfyUI with no claim only matters for the VRAM it pins: an empty server
# is ~0.4 GB, a resident render pipeline is 12-24 GB.
UNCLAIMED_COMFYUI_VRAM_MIB = 8192


# ---------------------------------------------------------------- utilities
def run(cmd, timeout=25, cwd=None):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=cwd)
        return p.stdout.strip(), p.returncode
    except Exception:
        return "", 1


def psql(sql, timeout=25):
    """Scalar query via psql; returns None when psql/DB is unavailable."""
    out, rc = run(["psql", "-At", "-d", DB, "-c", sql], timeout=timeout)
    if rc != 0 or not out:
        return None
    return out.splitlines()[0].strip()


def sched_state():
    try:
        with open(SCHED_DIR / "state.json") as fh:
            return json.load(fh)
    except Exception:
        return {}


def our_claim():
    """(status, current_job, ours_bool, job_id) for our 4090 slot."""
    st = sched_state()
    g = (st.get("gpus") or {}).get(GPU) or {}
    job = g.get("current_job")
    ours = ""
    try:
        with open(CLAIM_FILE) as fh:
            ours = json.load(fh).get("job_id", "")
    except Exception:
        pass
    return g.get("status"), job, (bool(job) and job == ours), ours


def comfyui_up():
    out, rc = run(["curl", "-s", "-m", "5", "-o", "/dev/null",
                   "-w", "%{http_code}", "http://127.0.0.1:8188/system_stats"])
    return out == "200"


def queue(job_id):
    """Derived FIFO queue for the GPU (job files), NOT state.json's queue field."""
    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location("gs", SCHED_DIR / "gpu_scheduler.py")
        if spec is None or spec.loader is None:
            return []
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        return m.read_queue(GPU)
    except Exception:
        return []


def last_telemetry():
    try:
        with open(TELE_FILE) as fh:
            lines = fh.read().strip().splitlines()
        return json.loads(lines[-1]) if lines else None
    except Exception:
        return None


# ------------------------------------------------------------------- checks
# Each check returns (key, title, severity, evidence) or None.

def check_venv_drift():
    """Repo pins vs installed versions — the silent breaker of relaunches.

    A `git pull` that bumps a pinned dep is invisible until the next launch,
    which then dies with ModuleNotFoundError. This is how ComfyUI broke.
    """
    req = COMFY_DIR / "requirements.txt"
    if not req.exists():
        return None
    pins = {}
    for line in req.read_text().splitlines():
        m = re.match(r"^\s*([A-Za-z0-9_.\-]+)\s*==\s*([^\s;#]+)", line)
        if m:
            pins[m.group(1).lower()] = m.group(2)
    if not pins:
        return None
    # Check only the packages installed in the ComfyUI venv.
    pip = COMFY_DIR / ".venv" / "bin" / "pip"
    if not pip.exists():
        return None
    out, rc = run([str(pip), "freeze"], timeout=60)
    if rc != 0:
        return None
    installed = {}
    for line in out.splitlines():
        if "==" in line:
            n, v = line.split("==", 1)
            # Distributions normalise '-' and '_' interchangeably
            # (comfyui-frontend-package installs as comfyui_frontend_package),
            # so compare normalised names or every wheel named with dashes
            # reads as "NOT INSTALLED".
            installed[n.lower().replace("-", "_")] = v
    drift = [
        f"{n}: pinned {v}, installed {installed.get(n.replace('-', '_'), 'MISSING')}"
        for n, v in pins.items()
        if n.replace("-", "_") in installed and installed[n.replace("-", "_")] != v
    ]
    missing = [f"{n}: pinned {v}, NOT INSTALLED"
               for n, v in pins.items() if n.replace("-", "_") not in installed]
    if drift or missing:
        return (
            "comfyui-venv-drift",
            "ComfyUI venv does not match requirements.txt (launch will fail)",
            "critical",
            "; ".join((drift + missing)[:6]),
        )
    return None


def check_launch_deps_importable():
    """The exact failure that killed the last relaunch, checked directly."""
    py = COMFY_DIR / ".venv" / "bin" / "python"
    if not py.exists():
        return None
    out, rc = run([str(py), "-c", "import comfy.storage"], timeout=60, cwd=str(COMFY_DIR))
    if rc != 0:
        tail = (out or "").strip().splitlines()[-3:]
        return (
            "comfyui-import-broken",
            "ComfyUI cannot import its own runtime modules (startup will crash)",
            "critical",
            " | ".join(tail) or "import comfy.storage failed",
        )
    return None


def foreign_hold_hours():
    """Hours the 4090 has been held by a non-turbo-carnival job; None if ours/idle.

    state.json timestamps are UTC ("...Z") — mktime would read them as local and
    skew the age by the UTC offset (calendar.timegm, not time.mktime).
    """
    st = sched_state()
    g = (st.get("gpus") or {}).get(GPU) or {}
    if g.get("status") not in ("busy", "claimed"):
        return None
    since = g.get("current_since")
    if not since:
        return None
    try:
        t = calendar.timegm(time.strptime(since[:19], "%Y-%m-%dT%H:%M:%S"))
    except Exception:
        return None
    return (time.time() - t) / 3600.0


def check_slot():
    """Our claim state. The 'someone else holds the 4090' case is NORMAL sharing.

    Filing every foreign hold as an issue produced a board entry that could never
    be actioned (the rules are explicit: never touch another project's job) and
    re-opened on every probe. Real contention is reported by check_render_starved
    (refusals + no output); here we only keep a record once a foreign hold is long
    enough to matter for capacity planning.
    """
    status, job, ours, ourjob = our_claim()
    q = queue(GPU)
    ahead = [j for j in q if j.get("project") == "turbo-carnival"]
    if status == "busy" and not ours and job:
        held = foreign_hold_hours()
        if ahead or (held is not None and held >= FOREIGN_HOLD_ALERT_H):
            return (
                "gpu-slot-other-project",
                f"4090 held by another project ({job})",
                "info",
                f"we hold no claim; held {held:.1f}h; our queue entries={len(ahead)}" if held
                else f"we hold no claim; our queue entries={len(ahead)}",
            )
        return None
    if ours and not comfyui_up():
        return (
            "comfyui-down-while-claimed",
            "We hold the GPU claim but ComfyUI is not answering",
            "critical",
            f"claim={ourjob}; port 8188 not answering /system_stats",
        )
    return None


def check_stuck_comfyui_jobs():
    n = psql("select count(*) from comfyui_jobs where status='submitted' "
             "and created_at < (now() at time zone 'UTC') - interval '30 minutes'")
    if n is None:
        return None
    try:
        n = int(n)
    except ValueError:
        return None
    if n > 0:
        oldest = psql("select min(created_at)::text from comfyui_jobs where status='submitted'")
        return (
            "stuck-comfyui-jobs",
            f"{n} ComfyuiJob rows stuck in 'submitted'",
            "warn",
            f"oldest={oldest}; terminal state never written (poller gap)",
        )
    return None


def check_stuck_pipeline_runs():
    n = psql("select count(*) from pipeline_runs where status='pending' "
             "and created_at < (now() at time zone 'UTC') - interval '2 hours'")
    if n is None:
        return None
    try:
        n = int(n)
    except ValueError:
        return None
    if n > 0:
        return (
            "stuck-pipeline-runs",
            f"{n} PipelineRun rows stuck in 'pending'",
            "warn",
            "runs that produced output still report pending (status never advanced)",
        )
    return None


def caption_provenance(hours=24):
    """How the window's captions were produced, from the posts' own metadata.

    scheduling_posts.caption_metadata now records the model that answered, why it
    was chosen (preferred_resident / preferred_not_resident(<model>)) and the
    failure reason when the caller shipped the placeholder. Without this the rate
    alone cannot say whether the caption path is dead, degraded to the fallback
    model, or merely blipping -- and the log line is gone by the next day.
    """
    sql = ("select coalesce(caption_metadata->>'model_selection', 'unrecorded'), "
           "count(*) from scheduling_posts "
           f"where created_at > (now() at time zone 'UTC') - interval '{hours} hours' group by 1 "
           "order by 2 desc")
    out, rc = run(["psql", "-At", "-d", DB, "-c", sql])
    if rc != 0 or not out:
        return None
    parts = []
    for line in out.splitlines():
        if not line.strip():
            continue
        name, _, count = line.rpartition("|")
        parts.append(f"{name} x{count}")
    return ", ".join(parts) or None


def caption_window(hours=24):
    """[(created_at, is_placeholder)] newest first; None when the DB is unreadable.

    None (not []) so the caller can stay silent without asserting the window is
    healthy -- an unreadable DB is a coverage hole, not a clean bill of health.
    """
    sql = ("select to_char(created_at, 'YYYY-MM-DD\"T\"HH24:MI:SSZ'), "
           "case when caption like 'Fresh look%' then 1 else 0 end "
           "from scheduling_posts "
           f"where created_at > (now() at time zone 'UTC') - interval '{hours} hours' "
           "order by created_at desc")
    out, rc = run(["psql", "-At", "-F", "|", "-d", DB, "-c", sql])
    if rc != 0:
        return None
    rows = []
    for line in out.splitlines():
        if not line.strip():
            continue
        ts, _, ph = line.rpartition("|")
        rows.append((ts.strip(), ph.strip() == "1"))
    return rows


def caption_verdict(rows, min_posts=CAPTION_MIN_POSTS,
                    alert_ratio=CAPTION_ALERT_RATIO):
    """Pure decision over a newest-first [(created_at, is_placeholder)] window.

    Returns (severity, fb, total, detail) or None.

    The trailing-window RATE alone cannot separate a dead caption path from one
    that was FIXED mid-window: the placeholders of the failed stretch stay inside
    the last 24h for up to a day after the fix, so a rate-only check keeps
    warning long after the condition stopped reproducing (2026-09-19: the caption
    model ladder shipped at 21:39Z while five pre-fix placeholders held the board
    at 62% for the rest of the day, with no post created since the fix).

    The failure is LIVE only while the NEWEST post in the window is a
    placeholder: a dead path substitutes the placeholder on EVERY post, so the
    newest one is always affected; once a real caption lands, the condition has
    stopped reproducing at the latest data point and the rate is history.
    """
    if not rows or len(rows) < min_posts:
        return None
    total = len(rows)
    fb = sum(1 for _, ph in rows if ph)
    if fb == 0:
        return None
    ratio = fb / total
    if ratio < alert_ratio:
        return None
    newest_ts, newest_ph = rows[0]
    if not newest_ph:
        return None
    last_real = next((ts for ts, ph in rows if not ph), None)
    first_ph = next((ts for ts, ph in reversed(rows) if ph), None)
    return (
        "warn" if ratio >= 0.5 else "info", fb, total,
        f"LIVE: newest post {newest_ts} is a placeholder; "
        f"placeholder stretch {first_ph}..{newest_ts}; "
        f"last real caption {last_real or 'none in window'}",
    )


def check_caption_fallback():
    """Placeholder-caption rate over the last 24h of scheduled posts.

    Silent degradation by design: ContentGenerator and Growth::RenderSalvage both
    substitute 'Fresh look' when the caption model fails, so a dead caption path
    ships placeholder captions to a live account with nothing in any log. The rate
    is the only signal that distinguishes that from a healthy pipeline -- but only
    while it is still reproducing, so the decision goes through caption_verdict()
    (see there for why the rate alone files a false positive after a fix).
    """
    rows = caption_window()
    if rows is None:
        return None
    verdict = caption_verdict(rows)
    if verdict is None:
        return None
    sev, fb, total, detail = verdict
    ratio = fb / total
    provenance = caption_provenance()
    return (
        "caption-fallback-rate",
        f"{fb} of {total} posts in 24h ship the placeholder caption 'Fresh look'",
        sev,
        f"placeholder rate {ratio:.0%} over {total} scheduled posts created in the "
        f"last 24h. {detail}. Both ContentGenerator and RenderSalvage substitute the "
        f"placeholder when the caption call fails, so this is a dead caption path, "
        f"not a content choice. Every recent render takes the TEXT path "
        f"(CaptionGeneration::Generator); the vision path is unreachable while "
        f"photos are imported without an ActiveStorage attachment. Mechanism: "
        f"gemma3:27b cannot be COLD-loaded on max395 - its 16.5 GB of weights sit "
        f"on the NFS model store (~40 MB/s) and exceed Ollama's ~300s llama-server "
        f"start timeout - so a call against a non-resident 27B burns the full "
        f"client timeout and still fails. CaptionGeneration::ModelConfig.resolve "
        f"now picks the model from Ollama's /api/ps (the preferred model when it "
        f"is resident, otherwise the fallback model), so a rate that persists "
        f"means BOTH models are failing. Provenance of this window's captions "
        f"(scheduling_posts.caption_metadata, recorded since 2026-09-19): "
        f"{provenance or 'unavailable'}. 'unrecorded' = a post created before the "
        f"metadata was persisted; grep the log for '[caption]' for those.",
    )


def check_render_acceptance():
    """Output != accepted output: photos created is the real acceptance signal."""
    n = psql("select count(*) from photos where created_at > (now() at time zone 'UTC') - interval '24 hours'")
    if n is None:
        return None
    try:
        n = int(n)
    except ValueError:
        return None
    if n == 0:
        return (
            "zero-accepted-output-24h",
            "No photo produced in 24h (pipeline running but accepting nothing)",
            "critical",
            "photos created in last 24h = 0",
        )
    return None


def check_render_starved():
    """The render loop is blocked on the shared GPU AND producing nothing.

    Replaces the old "another project holds the 4090" info entry as the contention
    signal. That entry fired on routine sharing (unactionable, and re-opened every
    probe); this fires only on the condition that actually starves the harness: the
    GPU was requested and refused (comfyui_unclaimed / cadence_blocked decisions)
    and ZERO photos were accepted in the same window. Canonical case: 2026-08-16 ->
    2026-09-16, ~96h of foreign holds with hourly refusals and a queue that drained
    to empty while every individual report looked merely "behind".

    Both halves are required: refusals alone are expected under sharing, empty
    output alone is check_render_acceptance's job (24h, critical).
    """
    photos = psql(f"select count(*) from photos where created_at > (now() at time zone 'UTC') - interval '{STARVE_WINDOW_H} hours'")
    refused = psql("select count(*) from growth_decisions where action in "
                   "('comfyui_unclaimed','cadence_blocked') and decided_at > (now() at time zone 'UTC') - "
                   f"interval '{STARVE_WINDOW_H} hours'")
    if photos is None or refused is None:
        return None
    try:
        photos, refused = int(photos), int(refused)
    except ValueError:
        return None
    if photos == 0 and refused >= 1:
        job = ((sched_state().get("gpus") or {}).get(GPU) or {}).get("current_job")
        held = foreign_hold_hours()
        return (
            "render-starved",
            f"no photo in {STARVE_WINDOW_H}h while the render request was refused {refused}x",
            "warn",
            f"photos_{STARVE_WINDOW_H}h=0 refusals_{STARVE_WINDOW_H}h={refused} "
            f"holder={job or 'none'}" + (f" held={held:.1f}h" if held else ""),
        )
    return None


def publish_verdict(due, oldest_h):
    """Pure: due-but-unpublished posts -> severity (or None when nothing is due)."""
    if due is None or due <= 0:
        return None
    if oldest_h is not None and oldest_h >= PUBLISH_CRITICAL_H:
        return "critical"
    return "warn"


def check_publish_liveness():
    """Posts that were DUE and never went out -- the publisher's absence, not the queue's size.

    Every other acceptance check counts what is SCHEDULED; nothing counted what
    actually leaves the building. The publisher is bin/scheduled_posting.sh, run
    hourly from the USER crontab (outside this repo and outside Hermes), so if it
    dies -- RVM/ruby drift, an expired Instagram token (code 190), a crash -- the
    queue keeps its scheduled rows, the watchdog keeps reporting "queue NOT
    starved", and the account silently stops posting. Measured from the
    authoritative predicate the publisher itself selects on (status='scheduled'
    + scheduled_at, status='draft' + optimal_time_calculated), so it does not
    depend on the publisher's own log or on any heartbeat.
    """
    row = psql(
        "select count(*) || '|' || coalesce(round(extract(epoch from "
        "(now() at time zone 'UTC') - min(due_at)) / 3600.0, 1), 0) from ("
        "  select scheduled_at as due_at from scheduling_posts "
        "   where status = 'scheduled' and scheduled_at is not null "
        f"    and scheduled_at < (now() at time zone 'UTC') - interval '{PUBLISH_GRACE_H} hours'"
        "  union all "
        "  select optimal_time_calculated as due_at from scheduling_posts "
        "   where status = 'draft' and optimal_time_calculated is not null "
        f"    and optimal_time_calculated < (now() at time zone 'UTC') - interval '{PUBLISH_GRACE_H} hours'"
        ") t"
    )
    if row is None:
        return None
    try:
        n_str, _, h_str = row.rpartition("|")
        due, oldest_h = int(n_str), float(h_str)
    except ValueError:
        return None
    sev = publish_verdict(due, oldest_h)
    if not sev:
        return None
    last = psql("select coalesce(max(posted_at)::text, 'never') from scheduling_posts "
                "where status = 'posted'")
    return (
        "publish-overdue",
        f"{due} scheduled post(s) are past their publish time and still unpublished",
        sev,
        f"oldest overdue {oldest_h:.1f}h (grace {PUBLISH_GRACE_H}h, critical at "
        f"{PUBLISH_CRITICAL_H}h); newest published={last}; "
        "publisher=bin/scheduled_posting.sh (user crontab, hourly)",
    )


def gpu_vram_used_mib():
    out, rc = run(["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits"])
    if rc != 0 or not out:
        return None
    try:
        return int(out.splitlines()[0].strip())
    except ValueError:
        return None


def check_comfyui_vram_unclaimed():
    """ComfyUI is up while NOBODY holds the GPU, pinning VRAM.

    The harm of an orphaned instance is the memory it holds on a shared card, not
    the open port -- a warm instance with no claim is what the next claimant OOMs
    against. Deliberately NOT fired when a claim exists (another project holding
    the slot and running the shared install is normal sharing, and the harness
    adopts foreign instances rather than killing them, so there is nothing to
    action). Sampled from hardware, not inferred from the port being open.
    """
    if not comfyui_up():
        return None
    g = (sched_state().get("gpus") or {}).get(GPU) or {}
    if g.get("status") in ("busy", "claimed"):
        return None
    used = gpu_vram_used_mib()
    if used is None or used < UNCLAIMED_COMFYUI_VRAM_MIB:
        return None
    return (
        "comfyui-vram-unclaimed",
        f"ComfyUI is up with no claim on the {GPU} while holding {used / 1024:.1f} GB",
        "warn",
        f"port 8188 answering, state={g.get('status')}, vram_used={used}MiB "
        f"(threshold {UNCLAIMED_COMFYUI_VRAM_MIB}MiB); the next claimant renders "
        "against this residue",
    )


def check_telemetry_oom():
    rec = last_telemetry()
    if not rec:
        return None
    if rec.get("oom_kill_events"):
        return (
            "comfyui-oom-kill",
            "ComfyUI was OOM-killed (cgroup)",
            "critical",
            json.dumps({k: rec.get(k) for k in
                        ("ts", "cgroup", "mem_peak_mb", "oom_kill_events")}),
        )
    if rec.get("exited") and rec.get("cgroup") and rec.get("vram_used_mib", 0) > 2000:
        return (
            "comfyui-exited-with-vram",
            "ComfyUI exited while still holding VRAM",
            "warn",
            json.dumps({k: rec.get(k) for k in ("ts", "vram_used_mib")}),
        )
    return None


def check_harness_log_growth():
    if not HARNESS_LOG.exists():
        return None
    size = HARNESS_LOG.stat().st_size
    lines = sum(1 for _ in open(HARNESS_LOG, errors="ignore"))
    if lines > 1500:
        return (
            "harness-log-unrotated",
            f"comfyui_harness.log is append-only and unrotated ({lines} lines, {size//1024} KB)",
            "info",
            "needs a retention window; full detail belongs in sections, not the log",
        )
    return None


def check_queue_growth():
    q = queue(GPU)
    ours = [j for j in q if j.get("project") == "turbo-carnival"]
    if len(ours) > 3:
        return (
            "own-queue-flood",
            f"{len(ours)} queued turbo-carnival entries on the 4090",
            "warn",
            "requester is re-requesting without observing grant state",
        )
    return None


def check_scheduler_dispatcher():
    """Scheduler liveness, read off the fields that ACTUALLY move.

    There is no scheduler daemon: state.json['updated_at'] was written once by
    `init` (2026-07-25) and is NOT touched by claim/activate/heartbeat/release.
    The fields that do move on every write are the global `version` counter and
    each GPU's entry, so keying this check on `updated_at` reported "frozen for
    1337h" on every probe while the 4090 was actively claimed and heartbeating
    (verified 2026-09-19). The condition worth alerting on is a claim being HELD
    while its heartbeat stopped — a box that died owning the slot.
    """
    st = sched_state()
    if not st or not st.get("gpus"):
        return (
            "scheduler-state-unreadable",
            "scheduler state.json is missing or has no GPU entries",
            "critical",
            f"path={SCHED_DIR / 'state.json'}",
        )
    stale = []
    now = time.time()
    for name, g in (st.get("gpus") or {}).items():
        if g.get("status") not in ("busy", "claimed"):
            continue
        hb = g.get("last_heartbeat") or g.get("current_since")
        if not hb:
            stale.append(f"{name}: {g.get('status')} job={g.get('current_job')} with NO heartbeat")
            continue
        try:
            # timestamps are UTC ("...Z"); mktime would read them as local and
            # produce a negative age east of UTC.
            t = calendar.timegm(time.strptime(hb[:19], "%Y-%m-%dT%H:%M:%S"))
        except Exception:
            continue
        age_min = (now - t) / 60.0
        if age_min > 45:  # scheduler stale deadline is 30 min; allow a missed tick
            stale.append(f"{name}: heartbeat {age_min:.0f}m stale (job={g.get('current_job')})")
    if stale:
        return (
            "scheduler-claim-heartbeat-stale",
            "a GPU claim is held with a heartbeat that went stale",
            "warn",
            "; ".join(stale),
        )
    return None


def check_render_for_terminal_run():
    """A render dispatched AFTER its run was already terminal = reworking dead work.

    `SelectNextJob` used to select every run that was not `completed`, so `failed`
    runs stayed workable forever. On 2026-09-19 that had the async submitter
    re-rendering deprecated sarah-carnival-v1 (pony/SDXL) and turbo-one-step runs
    from May/August alongside the growth harness's flux render — both model families
    stayed resident in VRAM and the flux job OOM'd at SamplerCustomAdvanced. The
    selector fix is guarded by a dispatch-boundary check in `SubmitJob`; this is the
    after-the-fact detector: a job created after its run's last write while that run
    is terminal. (Jobs created BEFORE the run was marked terminal are excluded — those
    are the mass-reconciled bookkeeping of runs abandoned while ComfyUI was down.)
    """
    n = psql("select count(*) from comfyui_jobs j "
             "join pipeline_runs r on r.id = j.pipeline_run_id "
             "where j.created_at > (now() at time zone 'UTC') - interval '24 hours' "
             "and r.status in ('failed','completed') "
             "and j.created_at > r.updated_at")
    if n is None:
        return None
    try:
        n = int(n)
    except ValueError:
        return None
    if n > 0:
        detail = psql("select p.name || ':run' || r.id || ' ' || r.status || ' #job' || j.id "
                      "from comfyui_jobs j join pipeline_runs r on r.id = j.pipeline_run_id "
                      "join pipelines p on p.id = r.pipeline_id "
                      "where j.created_at > (now() at time zone 'UTC') - interval '24 hours' "
                      "and r.status in ('failed','completed') "
                      "and j.created_at > r.updated_at order by j.id desc limit 5")
        return (
            "render-dispatched-for-terminal-run",
            f"{n} render(s) dispatched in the last 24h for runs already in a terminal status",
            "warn",
            f"dead-run rework or sync/async double-dispatch regressed; examples={detail}",
        )
    return None


def check_worker_running():
    """Sidekiq liveness — the failure that rotted 4 months of bookkeeping.

    JobPollerWorker (the only thing that advances ComfyuiJob/PipelineRun to a
    terminal status) and JobSubmitterWorker both live in Sidekiq. No Sidekiq
    process ran for this app from ~2026-05-28 to 2026-09-19: no ComfyuiJob was
    marked completed in that time, 241 rows accumulated as `submitted`, and
    JobSubmitterWorker back-pressured on them ("241 jobs in flight, waiting...")
    so nothing new could be submitted at all. The render path still worked
    (ContentGenerator submits synchronously), which is why it went unnoticed.
    """
    out, rc = run(["pgrep", "-af", "sidekiq"])
    ours = [l for l in out.splitlines()
            if "turbo-carnival" in l and "pgrep" not in l and "bash -c" not in l]
    if not ours:
        return (
            "sidekiq-worker-not-running",
            "No Sidekiq worker for turbo-carnival (job statuses cannot advance, submissions back-pressure)",
            "critical",
            "expected process 'sidekiq ... turbo-carnival'; run: systemctl --user status turbo-carnival-sidekiq",
        )
    return None


def check_backlog_backpressure():
    """Phantom in-flight jobs block JobSubmitterWorker entirely."""
    n = psql("select count(*) from comfyui_jobs where status in ('submitted','running')")
    if n is None:
        return None
    try:
        n = int(n)
    except ValueError:
        return None
    if n > 10:
        return (
            "submitter-backpressure",
            f"{n} jobs in non-terminal in-flight state — JobSubmitterWorker refuses to submit while these exist",
            "critical",
            "reconcile orphans (ids absent from ComfyUI history/queue) to a terminal status",
        )
    return None


def check_stranded_pending_jobs():
    """pending ComfyuiJob rows that nothing will ever submit.

    enqueue_oom_retry used to create a bare `pending` ComfyuiJob, but
    JobSubmitterWorker builds NEW jobs via SelectNextJob -> SubmitJob and never
    sweeps pending rows, so the OOM retry was a silent no-op that stranded the
    row forever (job 7542 sat pending 56 min with no comfyui_job_id while its
    run stayed OOM-failed). Fixed in PollJobStatus; this check keeps it fixed.
    """
    n = psql("select count(*) from comfyui_jobs where status='pending' "
             "and comfyui_job_id is null and created_at < (now() at time zone 'UTC') - interval '30 minutes'")
    if n is None:
        return None
    try:
        n = int(n)
    except ValueError:
        return None
    if n > 0:
        return (
            "stranded-pending-jobs",
            f"{n} ComfyuiJob rows pending with no comfyui_job_id — nothing submits them",
            "warn",
            "created by an OOM retry path that did not actually submit; "
            "verify PollJobStatus#enqueue_oom_retry calls SubmitJob",
        )
    return None


def _repo_defines_class(name):
    """True when app/ or a pack defines this constant (Zeitwerk leaf-name match)."""
    leaf = name.split("::")[-1]
    pat = re.compile(rf"\b(?:class|module)\s+{re.escape(leaf)}\b")
    for root in (APP / "app", APP / "packs", APP / "lib"):
        for p in root.rglob("*.rb"):
            try:
                if pat.search(p.read_text(errors="ignore")):
                    return True
            except OSError:
                continue
    return False


def check_zombie_jobs():
    """Sidekiq NameErrors for job classes this app cannot resolve.

    Two very different causes, and the fix for one is useless for the other:

    1. REAL ZOMBIE -- the class was deleted (or renamed) and stale retries keep
       re-running. Fix: purge Sidekiq's retry set.
    2. FOREIGN PAYLOAD -- the class never belonged to this app at all: the worker
       is consuming another project's queue, which happens when both share a
       Redis DB (Sidekiq defaults to DB 0). Canonical: on 2026-09-19 this worker
       ran TouchNeighborsJob / RecalculateCollectionCentroidJob /
       IdentifyPotentialDuplicatesJob -- all crawlr's, none in this repo -- for
       ~90 min because config/initializers/sidekiq.rb set no redis url. Purging
       the retry set (the first response) just made it recur. Fix: isolate the
       Redis DB (and keep the isolation in the initializer, not only in .env).

    The evidence names which of the two it is; the two are NOT interchangeable.
    """
    # 15-minute window, deliberately: a 1-hour lookback kept flagging the 189
    # pre-purge failures for a full hour AFTER the retry set was emptied, which is
    # the crying-wolf failure mode. Short window => the issue clears within
    # minutes of a real fix, and a genuinely recurring zombie still shows up.
    out, rc = run(["journalctl", "--user", "-u", "turbo-carnival-sidekiq",
                   "--since", "-15 min", "--no-pager"], timeout=40)
    if rc != 0 or not out:
        return None
    consts = re.findall(r"uninitialized constant ([A-Za-z0-9_:]+)", out)
    if not consts:
        return None
    counts = {}
    for c in consts:
        counts[c] = counts.get(c, 0) + 1
    foreign = sorted(c for c in counts if not _repo_defines_class(c))
    top = ", ".join(f"{k} x{v}" for k, v in
                    sorted(counts.items(), key=lambda kv: -kv[1])[:5])
    if foreign:
        hint = (f"{', '.join(foreign)} — NOT defined in this repo: the worker is "
                "consuming another project's queue (shared Redis DB). Check "
                "REDIS_URL / config/initializers/sidekiq.rb isolation; purging "
                "the retry set only makes it recur")
    else:
        hint = f"{top} — purge via Sidekiq::RetrySet (only entries whose klass resolves to no constant)"
    return (
        "sidekiq-zombie-jobs",
        f"{len(consts)} retries of jobs whose class does not exist"
        + (" (foreign queue)" if foreign else ""),
        "warn",
        f"{top} — {hint}",
    )


def check_probe_inputs():
    """Coverage guard: a probe that cannot measure must not report green.

    Every other check returns None for BOTH "healthy" and "could not read the
    input" (psql down, state.json missing or unparseable, NAS unmounted), so a
    blind probe reads as a clean board -- exactly the silence-looks-like-success
    failure this board exists to catch. File the coverage hole explicitly.
    """
    problems = []
    if psql("select 1") != "1":
        problems.append(f"psql cannot read {DB} (every DB-backed check reports nothing)")
    if not SCHED_DIR.exists():
        problems.append(f"{SCHED_DIR} is not mounted (no scheduler checks ran)")
    elif not ((sched_state().get("gpus") or {}).get(GPU)):
        problems.append(f"state.json has no '{GPU}' entry (slot/queue checks report nothing)")
    if not problems:
        return None
    return (
        "probe-inputs-unreadable",
        "ops probe cannot read its inputs -- the board is blind, not clean",
        "critical",
        "; ".join(problems),
    )


CHECKS = [
    check_probe_inputs,
    check_worker_running,
    check_backlog_backpressure,
    check_stranded_pending_jobs,
    check_zombie_jobs,
    check_venv_drift,
    check_launch_deps_importable,
    check_slot,
    check_stuck_comfyui_jobs,
    check_stuck_pipeline_runs,
    check_render_for_terminal_run,
    check_caption_fallback,
    check_render_acceptance,
    check_render_starved,
    check_publish_liveness,
    check_comfyui_vram_unclaimed,
    check_telemetry_oom,
    check_harness_log_growth,
    check_queue_growth,
    check_scheduler_dispatcher,
]


# -------------------------------------------------------------------- board
def issue_path(key):
    return BOARD / f"{key}.json"


def file_issue(key, title, severity, evidence, source="probe"):
    BOARD.mkdir(parents=True, exist_ok=True)
    p = issue_path(key)
    now = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    if p.exists():
        try:
            rec = json.loads(p.read_text())
        except Exception:
            rec = {}
        rec.update(title=title, severity=severity, evidence=evidence,
                   last_seen=now, status="open")
        rec["seen_count"] = rec.get("seen_count", 1) + 1
        rec.setdefault("first_seen", now)
        # A probe must not silently claim ownership of a hand-filed issue.
        if rec.get("source", "probe") == "probe":
            rec["source"] = source
    else:
        rec = {
            "key": key, "title": title, "severity": severity, "evidence": evidence,
            "status": "open", "first_seen": now, "last_seen": now,
            "seen_count": 1, "source": source, "notes": [],
        }
    p.write_text(json.dumps(rec, indent=2) + "\n")
    return rec


def append_note(rec, note):
    """Append a status note, keeping the board file a ROLLING WINDOW.

    Every run appends a note per open issue and nothing ever pruned, so the board
    -- the only durable record while cron delivery is broken -- grew by a note
    per issue per run, inflating the file every later run must read. Keep the
    newest NOTE_KEEP notes in the issue file and archive the overflow to
    ops/board/archive/<key>.jsonl: archived, never deleted.
    """
    notes = rec.setdefault("notes", [])
    notes.append({"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "note": note})
    if len(notes) > NOTE_KEEP:
        overflow, rec["notes"] = notes[:-NOTE_KEEP], notes[-NOTE_KEEP:]
        archive_notes(rec.get("key", "unknown"), overflow)


def archive_notes(key, notes):
    d = BOARD / "archive"
    d.mkdir(parents=True, exist_ok=True)
    with open(d / f"{key}.jsonl", "a") as fh:
        for n in notes:
            fh.write(json.dumps(n) + "\n")


def cmd_probe(_argv):
    found, quiet = [], []
    for chk in CHECKS:
        try:
            res = chk()
        except Exception as e:  # a broken probe must not break the probe run
            res = (f"probe-error-{chk.__name__}", f"probe {chk.__name__} raised", "warn", str(e)[:200])
        if res:
            rec = file_issue(*res)
            if res[2] == "critical":
                found.append(rec)
            else:
                quiet.append(rec)

    # Auto-close issues whose condition no longer reproduces.
    live = {r["key"] for r in found + quiet}
    for p in sorted(BOARD.glob("*.json")) if BOARD.exists() else []:
        try:
            rec = json.loads(p.read_text())
        except Exception:
            continue
        if rec.get("status") == "open" and rec.get("key") not in live \
                and rec.get("source", "probe") == "probe":
            rec["status"] = "auto-closed"
            append_note(rec, "condition no longer reproduces")
            p.write_text(json.dumps(rec, indent=2) + "\n")

    crit = [r for r in found]
    warns = [r for r in quiet if r["severity"] == "warn"]
    print(f"probe: {len(crit)} critical, {len(warns)} warn, "
          f"{len(quiet) - len(warns)} info")
    for r in crit + warns:
        print(f"  [{r['severity'].upper()}] {r['key']}: {r['title']}")
        print(f"      {r['evidence'][:200]}")
    return 0


def load_all(include_closed=False):
    if not BOARD.exists():
        return []
    recs = []
    for p in sorted(BOARD.glob("*.json")):
        try:
            rec = json.loads(p.read_text())
        except Exception:
            continue
        if include_closed or rec.get("status") == "open":
            recs.append(rec)
    recs.sort(key=lambda r: -SEV_ORDER.get(r.get("severity"), 0))
    return recs


def cmd_list(argv):
    recs = load_all(include_closed="--all" in argv)
    if not recs:
        print("board: no open issues")
        return 0
    print(f"{'SEV':9} {'KEY':32} {'SEEN':4} LAST SEEN")
    for r in recs:
        print(f"{r.get('severity',''):9} {r.get('key',''):32} "
              f"{r.get('seen_count',0):<4} {r.get('last_seen','')}")
        print(f"    {r.get('title','')}")
    return 0


def cmd_show(argv):
    if not argv:
        print("usage: tc_ops.py show KEY", file=sys.stderr)
        return 2
    p = issue_path(argv[0])
    if not p.exists():
        print(f"no such issue: {argv[0]}", file=sys.stderr)
        return 2
    print(p.read_text())
    return 0


def cmd_close(argv):
    if not argv:
        print("usage: tc_ops.py close KEY [-n|--note TEXT]", file=sys.stderr)
        return 2
    key = argv[0]
    # A note flag with no value used to IndexError; and when the flag itself
    # landed in the note slot the board kept the literal "--note" as the
    # resolution (observed 2026-09-19). Refuse rather than persist a non-note.
    note = ""
    for flag in ("--note", "-n"):
        if flag in argv:
            i = argv.index(flag) + 1
            note = argv[i] if i < len(argv) else ""
            break
    if not note or note.startswith("-"):
        print("usage: tc_ops.py close KEY [-n|--note TEXT] "
              "(a resolution note is required, and it must be the flag's value)",
              file=sys.stderr)
        return 2
    p = issue_path(key)
    if not p.exists():
        print(f"no such issue: {key}", file=sys.stderr)
        return 2
    rec = json.loads(p.read_text())
    rec["status"] = "closed"
    rec["closed_at"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    rec.setdefault("notes", [])
    append_note(rec, note)
    p.write_text(json.dumps(rec, indent=2) + "\n")
    print(f"closed {key}: {note}")
    # A probe-owned key is re-filed from live signals on the next tick unless the
    # CONDITION stops reproducing -- closing it by hand only works if the probe
    # agrees. Say so, or the same close gets attempted again every run.
    if rec.get("source", "probe") == "probe":
        print(f"note: '{key}' is probe-owned; the next probe re-files it unless "
              f"the condition itself stops reproducing. Fix the signal, not the "
              f"board entry.")
    return 0


def cmd_touch(argv):
    if not argv:
        return 2
    p = issue_path(argv[0])
    if not p.exists():
        return 2
    rec = json.loads(p.read_text())
    note = argv[1] if len(argv) > 1 else "progress"
    append_note(rec, note)
    p.write_text(json.dumps(rec, indent=2) + "\n")
    print(f"noted on {argv[0]}: {note}")
    return 0


def cmd_selftest(_argv):
    """Assert the pure decisions this board depends on (no DB, no board writes).

    Added after two board defects shipped: the caption check filed a false
    positive for a whole day after a fix (rate-only window), and `close --note`
    with no value persisted the literal string "--note" as a resolution. Both are
    decisions, so both are testable without a database.
    """
    import io
    import tempfile
    from contextlib import redirect_stdout

    T = lambda h: f"2026-09-19T{h}:00:00Z"
    fails = []

    def expect(name, got, want):
        if got != want:
            fails.append(f"{name}: got {got!r}, want {want!r}")

    # caption_verdict: (rows newest-first, expected severity or None)
    cases = [
        ("live-break", [(T(12), True), (T(11), True), (T(10), True), (T(9), False)], "warn"),
        ("recovered-head", [(T(12), False), (T(11), True), (T(10), True), (T(9), True)], None),
        ("single-blip", [(T(12), False), (T(11), True)], None),
        ("low-rate", [(T(12), True)] + [(T(11 - i), False) for i in range(4)], None),
        ("info-band", [(T(12), True), (T(11), False), (T(10), False)], "info"),
        ("no-posts", [], None),
    ]
    for name, rows, want in cases:
        v = caption_verdict(rows)
        expect(f"caption_verdict[{name}]", v[0] if v else None, want)

    # publish_verdict: (due count, oldest overdue hours, expected severity or None)
    publish_cases = [
        ("nothing-due", 0, 0.0, None),
        ("one-recent", 1, 1.5, "warn"),
        ("few-recent", 5, 4.0, "warn"),
        ("long-overdue", 1, 13.0, "critical"),
        ("age-unknown", 2, None, "warn"),
    ]
    for name, due, oldest, want in publish_cases:
        expect(f"publish_verdict[{name}]", publish_verdict(due, oldest), want)

    # close: a note flag with no value must be refused, not persisted.
    tmp = Path(tempfile.mkdtemp())
    tc_ops_board, BOARD_orig = BOARD, None  # noqa: F841 (readability)
    globals()["BOARD"] = tmp
    try:
        (tmp / "k.json").write_text(json.dumps(
            {"key": "k", "status": "open", "source": "probe", "notes": []}))
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc_missing = cmd_close(["k", "--note"])
        mid = json.loads((tmp / "k.json").read_text())
        with redirect_stdout(buf):
            rc_ok = cmd_close(["k", "-n", "resolved by selftest"])
        rec = json.loads((tmp / "k.json").read_text())
        expect("close[missing-note] rc", rc_missing, 2)
        expect("close[missing-note] untouched", (mid["status"], len(mid["notes"])), ("open", 0))
        expect("close[-n] rc", rc_ok, 0)
        expect("close[-n] note", rec["notes"][-1]["note"], "resolved by selftest")
        expect("close[probe-owned] warns", "probe-owned" in buf.getvalue(), True)

        # notes are a rolling window: overflow goes to board/archive, never deleted.
        prod = {"key": "w", "notes": []}
        for i in range(NOTE_KEEP + 2):
            append_note(prod, f"n{i}")
        arch = (tmp / "archive" / "w.jsonl")
        expect("note-window[kept]", len(prod["notes"]), NOTE_KEEP)
        expect("note-window[newest-kept]", prod["notes"][-1]["note"], f"n{NOTE_KEEP + 1}")
        expect("note-window[oldest-kept]", prod["notes"][0]["note"], "n2")
        expect("note-window[archived-lines]",
               len(arch.read_text().splitlines()) if arch.exists() else 0, 2)
    finally:
        globals()["BOARD"] = tc_ops_board
        import shutil
        shutil.rmtree(tmp, ignore_errors=True)

    for f in fails:
        print(f"FAIL {f}")
    print(f"selftest: {len(cases) + len(publish_cases) + 9} assertions, {len(fails)} failures")
    return 1 if fails else 0


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    cmd, argv = sys.argv[1], sys.argv[2:]
    return {
        "probe": cmd_probe, "list": cmd_list, "show": cmd_show,
        "close": cmd_close, "touch": cmd_touch, "selftest": cmd_selftest,
    }.get(cmd, lambda a: (print(__doc__), 2)[1])(argv)


if __name__ == "__main__":
    sys.exit(main())