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
  tc_ops.py warm-caption     load+pin the caption model on max395

Probe exits 0 always (cron-safe); prints CRITICAL/WARN counts. The probe blocks
up to TC_CAPTION_WARM_BUDGET seconds (default 240) ONLY when no caption model is
resident, because measuring "can a cold caption load complete" means attempting
one -- give it a timeout that accommodates that.
"""
from __future__ import annotations

import json
import calendar
import os
import re
import subprocess
import sys
import time
import urllib.request
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

# A foreign project holding the 4090 is the NORMAL shared-resource state and our
# rules forbid interfering with it, so a foreign hold is only an issue when it
# actually blocks US (one of our jobs waiting in that GPU's queue, or refusals
# with no output -- see check_render_starved). A pure time threshold filed a
# record that could never be actioned and re-opened on every probe.
# Starvation = we asked for the GPU and were refused, AND nothing came out.
STARVE_WINDOW_H = 12
# A burst is two newly scheduled posts close enough together that the hourly
# publisher (bin/scheduled_posting.sh) releases them in the SAME tick.
BURST_WINDOW_MINUTES = 60
# Placeholder-caption rate: a single fallback is a cold-load blip, a sustained
# rate means the caption path is dead and every post ships 'Fresh look'.
CAPTION_MIN_POSTS = 3
CAPTION_ALERT_RATIO = 0.3
# Publisher liveness (bin/scheduled_posting.sh, hourly from the user crontab):
# its worst case delay is one tick, so 3h absorbs a single missed run.
PUBLISH_GRACE_H = 3
PUBLISH_CRITICAL_H = 12
# EXPECTED-EVENT ABSENCE: the account posts ~3/day while the queue is healthy
# (measured inter-post gaps <= ~22h), so a multi-day silence is a failure -- and
# one no other check can see. check_publish_liveness counts rows that were DUE;
# a drained queue has none, so it reads green through a total outage (measured
# 2026-09-10 -> 09-17: eight silent days with every report green).
PUBLISH_GAP_WARN_H = 36
PUBLISH_GAP_CRITICAL_H = 96
# EXPECTED-EVENT ABSENCE, second case: the engagement feedback path. The insights
# command refreshes posts older than 24h on every run of the hourly publisher, so
# a live path is always well inside a day; a day of silence means nothing invoked
# it (measured 2026-09-20: newest insights write 2026-05-27, i.e. ~4 months).
INSIGHTS_STALE_WARN_H = 24
# The caption model server. /api/ps answers "is a caption model warm" without
# paying a cold load; the WARM-UP below is the only honest way to answer "can a
# cold load complete", because that is the failure mode that shipped the
# placeholder (see check_caption_path_cold).
CAPTION_ENDPOINT = "http://192.168.86.137:11434"
CAPTION_FALLBACK_MODEL = os.environ.get("CAPTION_FALLBACK_MODEL", "gemma3:4b").strip() or "gemma3:4b"
# The caption path's own budget before Ollama kills a slow load (~300s), kept
# slightly under it so a load that would be killed server-side is reported as a
# failure rather than as a slow success.
CAPTION_WARM_BUDGET_S = int(os.environ.get("TC_CAPTION_WARM_BUDGET", "240"))
# Keep the warmed model resident; the caption path sends the same value, so a
# successful probe leaves the next post answering in seconds instead of paying
# another cold load.
CAPTION_KEEP_ALIVE_S = int(os.environ.get("CAPTION_KEEP_ALIVE", str(6 * 60 * 60)))
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


def psql_lines(sql, timeout=25):
    """Multi-row query via psql; returns [] for an empty result, None when unreadable."""
    out, rc = run(["psql", "-At", "-d", DB, "-c", sql], timeout=timeout)
    if rc != 0:
        return None
    return [line.strip() for line in out.splitlines() if line.strip()]


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


def caption_resident_models():
    """Model names Ollama holds in memory on max395, or None when the probe failed.

    Non-loading: /api/ps answers "is a caption model warm" without paying a cold
    load. None means "cannot tell" and must never be reported as "cold".
    """
    out, rc = run(["curl", "-s", "-m", "5", f"{CAPTION_ENDPOINT}/api/ps"])
    if rc != 0 or not out:
        return None
    try:
        return [m.get("name") or m.get("model") for m in json.loads(out).get("models", [])]
    except Exception:
        return None


def caption_warm(model=None, budget=None, keep_alive=None):
    """Load `model` into Ollama on max395 and keep it resident.

    Returns (ok, seconds, error). This is the CAPABILITY measurement for the
    caption path: a model that is already resident answers in seconds, and one
    that is not has to be read off the (NFS) model store inside Ollama's ~300s
    llama-server start timeout -- which is exactly what fails when max395 is
    degraded, and what makes the caption path ship the placeholder.

    Deliberately blocking and deliberately state-changing: the only honest way
    to answer "can a cold load complete" is to attempt one, and a successful
    attempt leaves the path warm for the next post.
    """
    model = model or CAPTION_FALLBACK_MODEL
    budget = CAPTION_WARM_BUDGET_S if budget is None else budget
    keep_alive = CAPTION_KEEP_ALIVE_S if keep_alive is None else keep_alive
    body = json.dumps({
        "model": model,
        "prompt": "ok",
        "stream": False,
        "keep_alive": keep_alive,
        "options": {"num_predict": 1},
    }).encode()
    started = time.time()
    try:
        req = urllib.request.Request(
            f"{CAPTION_ENDPOINT}/api/generate", data=body,
            headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=budget) as resp:
            json.loads(resp.read().decode())
        return True, time.time() - started, None
    except Exception as e:
        return False, time.time() - started, f"{type(e).__name__}: {e}"


def caption_state_note():
    """One clause describing whether a caption call can run right now."""
    resident = caption_resident_models()
    if resident is None:
        return "ollama on max395 is unreachable (/api/ps probe failed)"
    if resident:
        return f"models resident on max395: {', '.join(resident)} (a caption call can run)"
    return ("no caption model is resident on max395, so the next caption call pays a "
            "cold load (a few tens of seconds when the box is healthy)")


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

    A foreign hold is not an issue by itself: our rules forbid touching another
    project's job, so a record filed on hold duration alone could never be
    actioned -- it sat open through 5 probes and two ops runs that both concluded
    "nothing to action". It is only a work item when it BLOCKS us: one of our own
    jobs is queued on that GPU. Real starvation (refusals with no output) is
    reported by check_render_starved.
    """
    status, job, ours, ourjob = our_claim()
    q = queue(GPU)
    ahead = [j for j in q if j.get("project") == "turbo-carnival"]
    if status == "busy" and not ours and job:
        if not ahead:
            return None
        held = foreign_hold_hours()
        return (
            "gpu-slot-other-project",
            f"4090 held by another project ({job}) with our job(s) queued behind it",
            "info",
            f"we hold no claim; held {held:.1f}h; our queue entries={len(ahead)}"
            if held
            else f"we hold no claim; our queue entries={len(ahead)}",
        )
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
        f"metadata was persisted; grep the log for '[caption]' for those. "
        f"Caption path now: {caption_state_note()}.",
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


def publish_gap_verdict(age_h):
    """Pure: hours since the newest published post -> severity (None when fresh)."""
    if age_h is None:
        return None
    if age_h >= PUBLISH_GAP_CRITICAL_H:
        return "critical"
    if age_h >= PUBLISH_GAP_WARN_H:
        return "warn"
    return None


def check_publish_gap():
    """EXPECTED-EVENT ABSENCE: the account stopped posting and nothing was due.

    check_publish_liveness measures rows that were DUE and never went out, so it
    is silent in exactly the failure that happened: the queue drained to zero and
    the account simply stopped -- no overdue row, no error, no log line. Measured
    2026-09-10 -> 09-17: eight days with no post and no scheduled_at row in the
    window, discovered afterwards only by counting posted_at by hand. Silence is
    a datum: the age of the newest posted post is the signal.
    """
    row = psql(
        "select coalesce(round(extract(epoch from (now() at time zone 'UTC') "
        "- max(posted_at)) / 3600.0, 1)::text, 'na') from scheduling_posts "
        "where status = 'posted' and posted_at is not null"
    )
    if row is None:
        return None
    try:
        age = float(row)
    except ValueError:
        return None
    sev = publish_gap_verdict(age)
    if not sev:
        return None
    n24 = psql("select count(*) from scheduling_posts where status = 'posted' "
               "and posted_at > (now() at time zone 'UTC') - interval '24 hours'")
    queued = psql("select count(*) from scheduling_posts where status in ('draft','scheduled') "
                  "and coalesce(scheduled_at, optimal_time_calculated) > (now() at time zone 'UTC')")
    return (
        "publish-gap",
        f"nothing published for {age:.0f}h (warn {PUBLISH_GAP_WARN_H}h, "
        f"critical {PUBLISH_GAP_CRITICAL_H}h)",
        sev,
        f"newest posted_at is {age:.1f}h old; posted in last 24h={n24}; future "
        f"queue={queued}. check_publish_liveness only counts rows that were DUE, so "
        "a drained queue is invisible to it -- this is the expected-event absence "
        "it cannot see (2026-09-10 -> 09-17: eight silent days).",
    )


def check_future_queue_empty():
    """The producer stopped: nothing at all is queued to publish.

    The harness refills to a target of ~21 scheduled posts, so an empty future
    queue is not a lull -- it is days of failed production (the queue drains one
    post per slot, ~3/day). It is also the EARLIEST signal of the 2026-09-10 ->
    09-17 silence: available days before check_publish_gap's threshold trips,
    because the last queued post has to publish before the account goes quiet.
    """
    n = psql("select count(*) from scheduling_posts where status in ('draft','scheduled') "
             "and coalesce(scheduled_at, optimal_time_calculated) > (now() at time zone 'UTC')")
    if n is None:
        return None
    try:
        n = int(n)
    except ValueError:
        return None
    if n > 0:
        return None
    last = psql("select coalesce(max(posted_at)::text, 'never') from scheduling_posts "
                "where status = 'posted'")
    return (
        "future-queue-empty",
        "no post is queued to publish: the producer has stopped",
        "warn",
        f"future draft/scheduled rows = 0 (target ~21); newest published={last}. "
        "Nothing is due yet, so check_publish_liveness stays green while the account "
        "counts down to silence -- the 2026-09-10 -> 09-17 outage looked exactly like "
        "this for days before the gap itself was measurable.",
    )


def insights_verdict(age_h):
    """Pure: hours since the newest insights write -> severity (None when fresh).

    age_h is None when NO posted item has insights at all -- that is a warn, not
    "unknown": the columns exist, the command that fills them works, so zero
    writes over a populated history means nothing is calling it.
    """
    if age_h is None:
        return "warn"
    if age_h >= INSIGHTS_STALE_WARN_H:
        return "warn"
    return None


def check_insights_stale():
    """EXPECTED-EVENT ABSENCE: the engagement feedback path exists but never runs.

    Scheduling::Commands::CollectPostInsights is implemented, its columns are read
    by Growth::WeeklyReview (per-pillar engagement steers hashtags and content
    direction), and it works when called by hand -- but nothing invoked it: no rake
    task, no cron, and its own selection had no ORDER BY, so even a manual run
    re-refreshed the same 25 oldest rows and never reached the posts with no
    insights at all. Measured 2026-09-20: newest insights write 2026-05-27, 107
    posted items with a provider id and NULL insights (newest id 327) while ids
    29-57 were re-collected -- every pillar's engagement read 0.0 for ~4 months,
    with no error, no log line and no overdue row to notice it by. The age of the
    newest insights write is the only signal such a path emits.
    """
    row = psql(
        "select (select count(*) from scheduling_posts where status = 'posted' "
        "and provider_post_id is not null "
        "and posted_at < (now() at time zone 'UTC') - interval '24 hours') || '|' || "
        "coalesce((select round(extract(epoch from (now() at time zone 'UTC') "
        "- max(insights_updated_at)) / 3600.0, 1)::text from scheduling_posts "
        "where status = 'posted' and provider_post_id is not null), 'na')"
    )
    if row is None:
        return None
    try:
        n_str, _, age_str = row.rpartition("|")
        candidates = int(n_str)
        age = None if age_str == "na" else float(age_str)
    except ValueError:
        return None
    if candidates <= 0:
        return None
    sev = insights_verdict(age)
    if not sev:
        return None
    age_txt = "never collected" if age is None else f"{age:.0f}h old"
    return (
        "insights-stale",
        f"engagement insights are {age_txt} ({candidates} posted item(s) older than 24h)",
        sev,
        f"newest insights_updated_at is {age_txt}; posted items older than 24h with "
        f"a provider id={candidates}. Growth::WeeklyReview aggregates "
        "engagement_rate per pillar to steer hashtags and content, so a stale "
        "insights column silently zeroes its only content signal. Producer: "
        "scheduling:collect_insights (bin/scheduled_posting.sh, hourly). Measured "
        "2026-09-20: newest write 2026-05-27 with 107 items NULL.",
    )


def colliding_pairs(times, window_min=BURST_WINDOW_MINUTES):
    """Pure: sorted epoch times -> the consecutive pairs inside the burst window."""
    return [
        (prev, cur)
        for prev, cur in zip(times, times[1:])
        if (cur - prev) < window_min * 60
    ]


def schedule_shape(times, cap, window_min=BURST_WINDOW_MINUTES):
    """Pure: sorted future publish epochs -> (over_cap_days, colliding_pairs).

    Days are UTC buckets (the app runs Time.zone = UTC, the same clock
    PostSlotPlanner's windows are built on). over_cap_days is
    [(day_start_epoch, count)] for every day holding MORE than `cap` posts.
    """
    per_day = {}
    for t in times:
        bucket = int(t // 86400) * 86400
        per_day[bucket] = per_day.get(bucket, 0) + 1
    over = [(d, n) for d, n in sorted(per_day.items()) if n > cap]
    return over, colliding_pairs(times, window_min)


def check_post_slot_bursts():
    """Newly scheduled posts placed on top of each other -> a burst release.

    Every producer used to stamp `scheduled_at = Time.current + offset_days.days`,
    so a post's wall-clock time was whatever time the producing tick ran. Posts
    made by successive ticks for the same target day therefore shared a publishing
    hour, and bin/scheduled_posting.sh (hourly) released them in one tick --
    measured 2026-09-19: posts 317/319/326 published 06:00:14Z / 06:00:26Z /
    06:00:38Z, three posts inside 24 s, while the cadence cap is 3/day.

    Growth::PostSlotPlanner now allocates spaced slots. This check measures the
    PRODUCER (posts created in the last 24 h), so it clears by itself once the fix
    is live instead of staying open on pre-fix rows that the queue still has to
    drain.
    """
    lines = psql_lines(
        "select extract(epoch from scheduled_at)::bigint from scheduling_posts "
        "where created_at > (now() at time zone 'UTC') - interval '24 hours' "
        "and scheduled_at is not null order by scheduled_at"
    )
    if lines is None:
        return None
    try:
        times = sorted(float(x) for x in lines)
    except ValueError:
        return None

    pairs = colliding_pairs(times)
    if not pairs:
        return None

    def stamp(t):
        return time.strftime("%m-%d %H:%M", time.gmtime(t))

    return (
        "post-slots-collide",
        f"{len(pairs)} pair(s) of posts created in the last 24h sit inside "
        f"{BURST_WINDOW_MINUTES} min of each other",
        "warn",
        "colliding: " + ", ".join(f"{stamp(a)}/{stamp(b)}" for a, b in pairs[:4])
        + "; the publisher now releases at most ONE post per tick "
        "(Scheduling::PostReleasePlan, 2026-09-20), so bunched slots no longer "
        "leave the account as a burst -- what remains here is a PRODUCER-shape "
        "smell (the slots are still too close; measured 2026-09-19: 3 posts inside "
        "24 s, before the pacing fix)",
    )


def check_post_schedule_shape():
    """The SHAPE of the future queue: days over the cadence cap, slots sharing a publisher tick.

    check_post_slot_bursts measures the PRODUCER (rows created in the last 24 h),
    so it goes green exactly when a pre-fix cluster ages out of that window --
    which is the same hour the cluster is RELEASED. Measured 2026-09-20: the
    probe stopped counting the 09-19 cluster at 15:15Z while posts 334/335/336
    were still queued to go out at 17:00Z, i.e. the board went green mid-burst.
    This measures what will actually leave the building: every future
    draft/scheduled row, grouped by publish day against the goal's posts_per_day,
    plus any consecutive pair close enough that bin/scheduled_posting.sh (hourly)
    releases both in one tick. Pre-fix rows are what it currently sees, and it
    clears itself: a day drops out once it is past.
    """
    rows = psql_lines(
        "select extract(epoch from scheduled_at)::bigint from scheduling_posts "
        "where status in ('draft','scheduled') and scheduled_at is not null "
        "and scheduled_at > (now() at time zone 'UTC') order by scheduled_at"
    )
    cap = psql("select coalesce(max(posts_per_day), 3) from growth_goals where status = 'active'")
    if rows is None or cap is None:
        return None
    try:
        times = sorted(float(x) for x in rows)
        cap = max(int(cap), 1)
    except ValueError:
        return None
    if not times:
        return None

    over, pairs = schedule_shape(times, cap)
    if not over and not pairs:
        return None

    day = lambda d: time.strftime("%m-%d", time.gmtime(d))  # noqa: E731
    stamp = lambda t: time.strftime("%m-%d %H:%M", time.gmtime(t))  # noqa: E731
    parts = []
    if over:
        parts.append(f"{len(over)} day(s) over the {cap}/day cap: "
                     + ", ".join(f"{day(d)}={n}" for d, n in over[:4]))
    if pairs:
        parts.append(f"{len(pairs)} pair(s) inside {BURST_WINDOW_MINUTES} min: "
                     + ", ".join(f"{stamp(a)}/{stamp(b)}" for a, b in pairs[:4]))

    return (
        "post-schedule-bunched",
        f"future queue still carries pre-fix slots: {'; '.join(parts)}",
        "warn" if over else "info",
        f"{'; '.join(parts)}; {len(times)} future post(s) queued. Producers now "
        "allocate through Growth::PostSlotPlanner AND the publisher releases at "
        "most ONE post per tick (Scheduling::PostReleasePlan), so these pre-fix "
        "rows no longer leave as a burst: the pair signal is the slot shape only, "
        "and the rows drain as the queue publishes (last bunched pair 09-25). No "
        "row edits needed -- the fix belongs in the releaser, which is where the "
        "burst actually happened.",
    )


def check_placeholder_caption_queued():
    """A queued post whose caption is still the failure artifact publishes as-is.

    check_caption_fallback measures the PRODUCER (rows created in the last 24 h)
    and goes silent as soon as the newest post has a real caption, so the
    placeholders a caption outage already wrote into the QUEUE are invisible --
    the same blind spot check_post_schedule_shape closes for slots. Measured
    2026-09-20: 5 unpublished posts carried 'Fresh look' (4 of them due inside
    two hours) while every caption probe read green. The repair is
    `rails captions:refresh_placeholders` (dry-run; APPLY=1 to write).
    """
    pred = ("status in ('draft','scheduled') and caption like 'Fresh look%' "
            "and (scheduled_at > (now() at time zone 'UTC') "
            "or optimal_time_calculated > (now() at time zone 'UTC'))")
    n = psql(f"select count(*) from scheduling_posts where {pred}")
    if n is None:
        return None
    try:
        n = int(n)
    except ValueError:
        return None
    if n == 0:
        return None

    rows = psql_lines(
        "select id || ' due ' || to_char(coalesce(scheduled_at, "
        "optimal_time_calculated), 'MM-DD HH24:MI') from scheduling_posts "
        f"where {pred} order by coalesce(scheduled_at, optimal_time_calculated)"
    )
    return (
        "caption-placeholder-queued",
        f"{n} unpublished post(s) still carry the placeholder caption and will publish with it",
        "warn",
        "queued placeholders: " + ", ".join((rows or [])[:6])
        + "; these are artifacts of the caption outage that wrote them; caption "
        "path now: " + caption_state_note()
        + "; the publisher repairs them before it sends (bin/scheduled_posting.sh "
        "runs captions:refresh_placeholders APPLY=1 ahead of "
        "scheduling:post_scheduled), so this clears at the next publishing tick -- "
        "a row that survives a tick means the captioner itself is down",
    )


def check_caption_path_cold():
    """A caption call made right now would FAIL -> the next post ships the placeholder.

    Every other caption check measures an OUTCOME (a placeholder rate over the
    producer window, a placeholder already sitting in the queue), so a broken
    caption path reads green until a post is created. This measures the
    CAPABILITY -- and it must MEASURE it, not infer it: the previous version
    fired whenever /api/ps was empty, which is the NORMAL state (Ollama unloads a
    model 300s after the last call), so it warned permanently on a healthy path
    and could never clear. The one thing that actually breaks the path is a cold
    load that cannot finish inside Ollama's ~300s llama-server start timeout
    (measured 2026-09-20 pre-reboot: gemma3:4b failed at 301.4s twice; the same
    load takes ~30s on the healthy box), so this attempts one.

    The attempt doubles as the repair: it warms the configured fallback and pins
    it resident, so a successful probe leaves the next post answering in seconds.
    Costs up to CAPTION_WARM_BUDGET_S when the path is cold, nothing when a model
    is already resident. TC_CAPTION_WARM=0 turns the attempt off (the check then
    reports nothing rather than guessing).
    """
    resident = caption_resident_models()
    if resident is None or resident:
        return None
    if os.environ.get("TC_CAPTION_WARM", "1") == "0":
        return None

    ok, secs, err = caption_warm()
    if ok:
        return None
    return (
        "caption-path-cold",
        f"a cold caption load on max395 did not finish in {CAPTION_WARM_BUDGET_S}s: "
        "the next post ships the placeholder",
        "warn",
        f"no caption model was resident (/api/ps on 192.168.86.137 = []) and the "
        f"warm-up of {CAPTION_FALLBACK_MODEL} failed after {secs:.1f}s: {err}. "
        "CaptionGeneration::ModelConfig walks its ladder to the fallback and then to "
        "the placeholder, so any post created before the load succeeds carries 'Fresh "
        "look'. Ollama kills a slow load at ~300s (llama-server start timeout) and the "
        "cause is on max395: NFS model-store read speed, or memory pressure. Fix "
        "(max395): raise OLLAMA_LOAD_TIMEOUT in "
        "/etc/systemd/system/ollama.service.d/override.conf, or preload the fallback "
        "model and pin it resident (keep_alive=-1).",
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
    check_caption_path_cold,
    check_placeholder_caption_queued,
    check_render_acceptance,
    check_render_starved,
    check_publish_liveness,
    check_publish_gap,
    check_insights_stale,
    check_future_queue_empty,
    check_post_slot_bursts,
    check_post_schedule_shape,
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

    # publish_gap_verdict: hours since the newest published post -> severity.
    # The 2026-09-10 -> 09-17 outage is the case this exists for (8 days silent).
    gap_cases = [
        ("fresh", 0.5, None),
        ("normal-inter-post-gap", 22.3, None),
        ("just-under-warn", PUBLISH_GAP_WARN_H - 0.1, None),
        ("at-warn", float(PUBLISH_GAP_WARN_H), "warn"),
        ("silent-day", 50.0, "warn"),
        ("eight-silent-days", 192.0, "critical"),
        ("unknown", None, None),
    ]
    for name, age, want in gap_cases:
        expect(f"publish_gap_verdict[{name}]", publish_gap_verdict(age), want)

    # insights_verdict: hours since the newest insights write -> severity. None
    # means no posted item has insights at all (the ~4-month case this exists for).
    insights_cases = [
        ("fresh", 1.5, None),
        ("same-day", 20.0, None),
        ("just-under-warn", INSIGHTS_STALE_WARN_H - 0.1, None),
        ("at-warn", float(INSIGHTS_STALE_WARN_H), "warn"),
        ("four-months", 2760.0, "warn"),
        ("never-collected", None, "warn"),
    ]
    for name, age, want in insights_cases:
        expect(f"insights_verdict[{name}]", insights_verdict(age), want)

    # colliding_pairs: sorted epoch seconds -> pairs inside the burst window.
    burst_cases = [
        ("empty", [], 0),
        ("single", [1000.0], 0),
        ("spaced-90m", [0.0, 5400.0, 10800.0], 0),
        ("burst-24s", [0.0, 24.0, 48.0], 2),
        ("pair-only", [0.0, 1200.0, 20000.0], 1),
    ]
    for name, times, want in burst_cases:
        expect(f"colliding_pairs[{name}]", len(colliding_pairs(times)), want)

    # schedule_shape: (sorted future epochs, cap) -> (over-cap days, colliding pairs).
    # The same instants the old producers stamped: creation time-of-day, so a day
    # collects whatever the producing tick's clock was.
    D = 86400.0
    shape_cases = [
        # one spaced post per day, all under cap -> nothing to report
        ("healthy", [D * 10 + 32400, D * 11 + 36000, D * 12 + 39600], 3, 0, 0),
        # 6 posts on one day, 3 of them inside an hour (the live 2026-09-20 shape)
        ("over-cap-burst",
         sorted([D * 10 + 15600, D * 10 + 19740, D * 10 + 54900,
                 D * 10 + 57660, D * 10 + 59100, D * 10 + 61800]), 3, 1, 3),
        # exactly at cap is fine; only MORE than cap is a violation
        ("at-cap", [D * 10 + 32400, D * 10 + 36000, D * 10 + 39600], 3, 0, 0),
        # over cap on two days, no sub-hour pair
        ("two-over-cap", [D * 10 + i * 3600 for i in range(4)]
         + [D * 11 + i * 3600 for i in range(5)], 3, 2, 0),
        ("empty", [], 3, 0, 0),
    ]
    for name, times, cap, want_over, want_pairs in shape_cases:
        over, pairs = schedule_shape(sorted(times), cap)
        expect(f"schedule_shape[{name}].over", len(over), want_over)
        expect(f"schedule_shape[{name}].pairs", len(pairs), want_pairs)

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
    print(f"selftest: {len(cases) + len(publish_cases) + len(gap_cases) + len(insights_cases) + len(burst_cases) + 2 * len(shape_cases) + 9} assertions, {len(fails)} failures")
    return 1 if fails else 0


def cmd_warm_caption(_argv):
    """Load and pin the caption model so the next post does not pay a cold load."""
    resident = caption_resident_models()
    if resident is None:
        print("caption host unreachable (/api/ps failed) -- nothing warmed")
        return 1
    if resident:
        print(f"already warm: {', '.join(resident)}")
        return 0
    ok, secs, err = caption_warm()
    if ok:
        print(f"warmed {CAPTION_FALLBACK_MODEL} in {secs:.1f}s "
              f"(keep_alive={CAPTION_KEEP_ALIVE_S}s)")
        return 0
    print(f"warm-up FAILED after {secs:.1f}s: {err}")
    return 1


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    cmd, argv = sys.argv[1], sys.argv[2:]
    return {
        "probe": cmd_probe, "list": cmd_list, "show": cmd_show,
        "close": cmd_close, "touch": cmd_touch, "selftest": cmd_selftest,
        "warm-caption": cmd_warm_caption,
    }.get(cmd, lambda a: (print(__doc__), 2)[1])(argv)


if __name__ == "__main__":
    sys.exit(main())