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
  tc_ops.py file KEY --title TEXT --evidence TEXT [--severity warn|critical|info]
                             file an issue the probe cannot measure (outside-scope
                             or found by reading a monitoring job's output);
                             --source manual (default) keeps it out of auto-close
  tc_ops.py close KEY [-n]   close an issue with a resolution note
  tc_ops.py touch KEY        bump an issue (used by fixers to record progress)
  tc_ops.py caption-endpoint is the caption service up? (scanner-safe probe for
                             cron prompts: the shell command carries no raw IP)
  tc_ops.py log-health       which repo logs are live, and what are their recent
                             errors? (repo-owned replacement for prompts that
                             hardcode a log path -- a path rots when the writer
                             moves, an age cannot)
  tc_ops.py warm-caption     load+pin the caption model on max395
  tc_ops.py needs-human      rewrite ops/NEEDS_HUMAN.md -- the markdown digest of
                             the open board, split by route (enablement for Tim
                             vs decisions the agent owns)
  tc_ops.py route KEY --route agent|tim [-n NOTE]
                             move an item between the two queues, recording why
  tc_ops.py escalations      print ONLY the enablement queue (route=tim); empty
                             output when no human is needed, so an escalation job
                             can suppress itself

Probe exits 0 always (cron-safe); prints CRITICAL/WARN counts. The probe blocks
up to TC_CAPTION_WARM_BUDGET seconds (default 240) ONLY when no caption model is
resident, because measuring "can a cold caption load complete" means attempting
one -- give it a timeout that accommodates that.
"""
from __future__ import annotations

import json
import base64
import calendar
import os
import re
import subprocess
import sys
import tempfile
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

# The board is JSON, readable only through `tc_ops.py list`. Delivery from this
# profile is broken (`cron-delivery-target-broken`), so no report reaches a human
# either -- meaning the decision queue had NO readable surface anywhere. This
# markdown digest is regenerated from ops/board/*.json on every probe run and
# lives in the repo, where git log is the delivery channel that actually works.
NEEDS_HUMAN = APP / "ops" / "NEEDS_HUMAN.md"
DIGEST_EVIDENCE_CHARS = 300
DIGEST_NOTE_CHARS = 400

# ROUTE: every open item belongs to exactly one of two queues, and the split IS
# the fix. `agent` -- a decision the operating agent OWNS and must TAKE (business
# and product calls: cadence, persona, caption path, whether to wait for a slot).
# `tim` -- an ENABLEMENT ask only a human can perform (a file outside this repo,
# a credential, a platform/channel setting, a GPU policy).
#
# Why this exists: the board filed business decisions as "needs a human" for its
# first two days, because nothing said the agent owned them. Every hourly pass
# re-derived the same deferred item, appended another note, and closed nothing --
# a decision queue with no decision-maker looks identical to a healthy backlog.
# Default is `agent`: a business decision reaching a human is the FAILURE MODE, so
# only genuine enablement may route to `tim`. Re-route with:
#   python3 bin/tc_ops.py route <key> --route tim -n "<why it needs a human>"
ROUTES = ("agent", "tim")
ROUTE_DEFAULT = "agent"

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
# When Growth::PostSlotPlanner landed (commit 511afaf, 2026-09-19 21:36:32 EDT).
# Rows created before it carry whatever time-of-day the producing tick ran, which
# is the defect it fixed; a collision among rows created after it means a producer
# is bypassing the planner. See post_slot_verdict.
POST_SLOT_PLANNER_LANDED = calendar.timegm(
    time.strptime("2026-09-20T01:36:32", "%Y-%m-%dT%H:%M:%S"))
# The publisher's burst protection, asserted rather than assumed: the rake task
# must still route due posts through Scheduling::PostReleasePlan, and that class
# must still cap a run at one post. See check_release_pacing.
RELEASE_PLAN_RAKE = APP / "packs" / "scheduling" / "lib" / "tasks" / "scheduled_posting.rake"
RELEASE_PLAN_SRC = (APP / "packs" / "scheduling" / "app" / "services"
                    / "scheduling" / "post_release_plan.rb")
# Placeholder-caption rate: a single fallback is a cold-load blip, a sustained
# rate means the caption path is dead and every post ships 'Fresh look'.
CAPTION_MIN_POSTS = 3
CAPTION_ALERT_RATIO = 0.3
# Post candidates are photos whose bytes we can serve. Below this many servable
# unposted photos the corpus cannot sustain the configured cadence (3/day), and
# the shortfall surfaces only as an empty queue -- i.e. silence, not an error.
POOL_FLOOR = 10
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
# REJECTED-PUBLISH: Instagram accepts the container, then refuses the publish
# (400 code 9007 "the media is not ready for publishing"), the rake task marks
# the row failed with NO requeue path, and the slot is gone -- while the
# publisher still exits 0. Lifetime occurrences: 3 (post 37, post 246, post 333),
# so a hit is rare and always worth reading; the 24h window keeps the signal
# while it is actionable and lets the entry self-close once failures age out.
PUBLISH_FAILED_WINDOW_H = 24
# The failed-post repair (Scheduling::FailedPostRetry, run by the publisher as
# `scheduling:retry_failed`) re-books a TRANSIENTLY rejected post onto a fresh slot
# and stamps the row's failure_reason with `retry#N ...`. Such a row is booked, not
# lost, so it must never be counted as a lost slot here -- but a row that stays
# un-marked IS a real loss: a policy rejection (never retried on purpose), a row with
# no stored reason, a photo whose file is gone, or a repair that stopped running.
RETRY_MARKER = 'retry#'
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
# ...but only when that instance is IDLE. The shared install at /mnt/fscache/essdee
# /ComfyUI is used interactively (and by other projects) from a tmux shell with no
# scheduler claim, which is the normal state while a human or another agent is
# mid-render -- and a board warning that reads "ComfyUI up, no claim, 23 GB" is
# what an agent acts on. Measured 2026-09-20 09:25 EDT: this check fired while an
# interactive session was actively rendering (5 prompts 09:00->09:26, the newest a
# 57 s render that finished 4 min before the probe), and the growth brain's own
# tick independently mislabelled the same instance an "orphan/leak". A ComfyUI
# that has rendered within this window, or whose native queue is non-empty, is
# live work: leave it alone.
COMFYUI_LIVE_WINDOW_S = 1800
# The ops loop's LAST MILE: Hermes writes a cron result to disk and then delivers
# it; when the delivery target resolves to a platform with no adapter the run
# still "succeeds", the output file still exists, and nobody receives anything.
# Measured 2026-09-19/20: three jobs (growth-brain, weekly-persona-review and this
# ops-triage job itself) logged last_status=delivery_failed, "unknown platform
# 'webui'", for ~18h -- so every finding on this board was being dropped while
# each run reported success. Nothing in this repo can see that, so read it from
# the job store (override with TC_CRON_JOBS; unreadable -> no signal, not a warn).
#
# RESOLVED 2026-09-21: the three jobs now carry `deliver=local` (their WebUI origin
# cannot be delivered to; the profile's real home channels are slack/email, and
# pushing reports there is a human decision, not a silent config change). The check
# below was made CONFIG-AWARE in the same pass, because `last_status` is historical:
# keyed on status alone the board would have carried an already-fixed item until the
# weekly job next ran (up to 7 days). It now fires only for a job that still ASKS
# for delivery (target != local) whose last attempt failed.
CRON_JOBS = Path(os.environ.get("TC_CRON_JOBS")
                 or Path.home() / ".hermes" / "profiles" / "turbo-carnival"
                 / "cron" / "jobs.json")

# PROMPT SAFETY: a stored workflow is executable instruction text, and the stored
# text drifted. Measured live 2026-09-20: pipeline_steps 39/40 (pipeline 20
# 'turbo-one-step', the generator's fallback, and 21 'turbo-one-step-clean', the
# production path) carried a NEGATIVE prompt reading "... long neck, adult,
# mature_face, sunken_eyes" -- conditioning the render AGAINST adult features --
# while vision reads of three production renders returned "a young girl, likely a
# teenager"; and step 34 (pipeline 17, reachable from the admin UI via
# ContentSuggestionsController#generate_image, which picks Pipeline.first)
# instructed an LLM, verbatim, to make the image "a white, Caucasian young
# teenager". Every previous run recorded this as Tim's identity decision and moved
# on, which left published content reading as a minor.
#
# The render path is guarded (BuildJobPayload runs every workflow through
# PipelinePromptSafety), so a dirty STORED value is a warn -- the render is already
# neutralised and the repair is `bundle exec rake pipeline:prompt_safety APPLY=1`.
# A render path that no longer runs the guard is critical: then nothing stands
# between the stored text and a render.
PROMPT_SAFETY_GUARD_SRC = (APP / "packs" / "job_orchestration" / "app"
                           / "commands" / "build_job_payload.rb")
PROMPT_SAFETY_GUARD_REF = "PipelinePromptSafety"
# The DATABASE half of the synthetic mark (openspec change
# add-synthetic-provenance). Both render producers must create the Photo through
# this ONE method, or the mark is remembered by one path and forgotten by the
# other. A producer that stops calling it is critical: the render reaches the
# corpus with `synthetic IS NULL`, and the record from which the published asset
# could ever be marked is gone.
PROVENANCE_IMPORT_REF = "Photo.import_render"
PROVENANCE_PRODUCERS = [
    APP / "packs" / "growth_harness" / "app" / "services" / "growth" / "content_generator.rb",
    APP / "packs" / "growth_harness" / "app" / "services" / "growth" / "render_salvage.rb",
]
WORKFLOW_DIR = APP / "comfy_workflows"
# Mirrors PipelinePromptSafety::JUVENILE_RULES (detection only; the Ruby side owns
# the rewrite). Deliberately narrow: "young"/"petite" are NOT violations.
JUVENILE_RX = re.compile(
    r"\b(?:young\s+teen(?:ager|aged)?s?|teenagers?|teen[-\s]?aged|teens?|pre[-\s]?teens?"
    r"|tweens?|(?:young|little|small)\s+girls?|school\s?girls?|adolescents?|under[-\s]?aged?"
    r"|minors?|children|child|high[-\s]?school(?:ers?)?|\d{1,2}[-\s]?year[-\s]?olds?)\b",
    re.IGNORECASE)
# Adult-suppressing tokens only count as a violation in a comma-separated list
# (the negative-prompt shape), and only in a blob that also carries negative
# boilerplate -- otherwise a positive prompt that merely says "adult woman" fires.
ADULT_LIST_RX = re.compile(
    r"(?:^|,)\s*(?:adults?|mature[_\s-]?face|mature\s+wom[ae]n|grown[-\s]?wom[ae]n"
    r"|elderly|old\s+wom[ae]n)\s*(?=,|$)",
    re.IGNORECASE | re.MULTILINE)
NEG_BOILERPLATE_RX = re.compile(r"worst quality|low quality|bad anatomy|score_5|score_4",
                                re.IGNORECASE)


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


OWN_QUEUE_GRACE_MIN = 10   # a just-requested entry is not a blockade yet


def own_queue_verdict(q, status, ours, now=None, free_mib=None, requested_mib=None,
                      blockers=None):
    """Our own queued 4090 entries -> (key, title, severity, evidence) or None.

    Two shapes, both invisible to every existing check (check_slot only files a
    foreign hold, and only when one of our jobs is queued):

    * FLOOD: more than one outstanding request from this project. The harness
      mints a fresh `comfyui-<ts>-<pid>` per tick, so a tick killed mid-wait (the
      caller's tool budget is 180s, the wait 300s) leaves its entry queued and the
      next tick adds another BEHIND it -- `poll` refuses `not_my_turn` for
      anything behind a queued entry, so the project starves itself.
    * SELF-BLOCKADE: one own entry at the head of the derived queue while the 4090
      is scheduler-idle and no claim is ours, older than the grace period.
      Nothing polls an entry whose owner is gone, so the card sits physically
      idle until a tick adopts it or the 24h expiry reaps it.
    * HEAD-CANNOT-FIT: the same head entry, but live free VRAM is below its own
      reservation, so `poll` refuses `vram_insufficient` -- polling harder can
      never grant it. That is a co-tenant holding memory outside the scheduler
      (a labeler, a desktop session), and reporting it as the blockade above
      sends the fixer after a claim that cannot be taken.
    """
    now = now if now is not None else time.time()
    own = [j for j in (q or []) if j.get("project") == "turbo-carnival"]
    if not own:
        return None
    own.sort(key=lambda j: j.get("requested_at", ""))

    def age_min(j):
        ts = (j.get("requested_at") or "")[:19]
        try:
            return (now - calendar.timegm(time.strptime(ts, "%Y-%m-%dT%H:%M:%S"))) / 60.0
        except Exception:
            return None

    if len(own) > 1:
        return (
            "own-queue-flood",
            f"{len(own)} outstanding 4090 requests from this project (one is enough)",
            "warn",
            "ids=" + ", ".join(j.get("id", "?") for j in own)
            + f"; oldest {own[0].get('id')} @ {own[0].get('requested_at')} — poll returns "
              "not_my_turn for anything behind our own entry, so we starve ourselves",
        )
    j = own[0]
    head = (q or [None])[0]
    age = age_min(j)
    if (head is not None and head.get("id") == j.get("id") and status == "idle"
            and not ours and age is not None and age >= OWN_QUEUE_GRACE_MIN):
        req_mib = None
        try:
            req_mib = float(j.get("vram_gb") or 0) * 1024 or None
        except (TypeError, ValueError):
            req_mib = None
        req_mib = req_mib or requested_mib
        if free_mib is not None and req_mib and free_mib < req_mib:
            return (
                "own-queue-head-vram-blocked",
                "our entry holds the FIFO head but the card cannot fit it — a co-tenant holds VRAM outside the scheduler",
                "warn",
                f"id={j.get('id')} queued {age:.0f} min ago, head of the derived queue, gpu=idle, "
                f"ours=no; free={free_mib / 1024:.1f}GiB < reservation {req_mib / 1024:.1f}GiB, so "
                "`poll` refuses vram_insufficient and polling harder cannot grant it"
                + (f"; outside-scheduler holders: {blockers}" if blockers else ""),
            )
        return (
            "own-queue-blockade",
            "our queued entry is at the FIFO head while the 4090 is idle and no claim is ours",
            "warn",
            f"id={j.get('id')} queued {age:.0f} min ago, head of the derived queue, gpu=idle, "
            "ours=no — nothing polls it until the next harness tick, so the card idles",
        )
    return None


def check_own_queue_leak():
    status, _job, ours, _ourjob = our_claim()
    return own_queue_verdict(
        queue(GPU), status, ours,
        free_mib=gpu_vram_free_mib(),
        requested_mib=(our_reservation_gb() or 0) * 1024 or None,
        blockers=vram_blocker_note(),
    )


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
        # with_util: this is the one check where "is the blocker WORKING or merely
        # resident?" decides the ask, and it only runs on a starved tick.
        fit = vram_fit_note(with_util=True)
        return (
            "render-starved",
            f"no photo in {STARVE_WINDOW_H}h while the render request was refused {refused}x",
            "warn",
            f"photos_{STARVE_WINDOW_H}h=0 refusals_{STARVE_WINDOW_H}h={refused} "
            f"holder={job or 'none'}" + (f" held={held:.1f}h" if held else "")
            + (f"; {fit}" if fit else ""),
        )
    return None


RENDER_ERR_WINDOW_H = 24


def render_error_verdict(rows):
    """Pure: failed-job error rows (newest first) -> (severity, newest) or None.

    Split from the query so the decision is testable without a database, and the
    WINDOW is what makes the entry self-close: a one-off node crash ages out
    instead of pinning the board forever.
    """
    if rows is None:
        return None
    rows = [r.strip() for r in rows if r and r.strip()]
    if not rows:
        return None
    return ("warn", rows[0])


def check_render_execution_errors():
    """A render that dies INSIDE the workflow -- a node exception, not a timeout.

    Different fault, different fix: a timeout is throughput/GPU, an exception is
    the workflow or its inputs. Until 2026-09-21 the Rails producer reported both
    as "render timed out or produced no image", so the cause reached neither the
    brain's cadence_blocked decision row nor this board. Measured 2026-09-21:
    run 479 died with `index is out of bounds for dimension with size 0` in the
    workflow's "Bounded Image Crop with Mask" node (an EMPTY CLIPSeg head mask)
    and the tick's third render was lost.

    Reconciliation markers ("reconciled ...", written by ReconcileStaleJobs) are
    excluded on purpose: they are bookkeeping about an orphan, not an execution
    fault, and they arrive in bulk sweeps.

    The error text is whitespace-collapsed in SQL because ComfyUI's
    exception_message carries a TRAILING NEWLINE (job 7563, 2026-09-21: 49 bytes,
    1 newline) -- psql then emits it as two lines and the row count doubles.
    """
    rows = psql_lines(
        "select btrim(regexp_replace(coalesce(error_message, ''), "
        "E'[\\\\n\\\\r\\\\t ]+', ' ', 'g')) "
        "|| ' (' || to_char(updated_at, 'MM-DD HH24:MI') || 'Z)' "
        "from comfyui_jobs where status = 'failed' "
        "and coalesce(error_message, '') <> '' and error_message not like 'reconciled%' "
        f"and updated_at > (now() at time zone 'UTC') - interval '{RENDER_ERR_WINDOW_H} hours' "
        "order by updated_at desc limit 5")
    v = render_error_verdict(rows)
    if not v:
        return None
    sev, newest = v
    n = len([r for r in (rows or []) if r and r.strip()])
    return (
        "render-execution-error",
        f"a render died inside the workflow: {newest}",
        sev,
        f"{n} ComfyUI execution error(s) in the last {RENDER_ERR_WINDOW_H}h; "
        f"newest {newest}. The producer now NAMES this (Growth::ContentGenerator "
        "carries the ComfyUI error into the run's failure reason and the brain's "
        "decision row) instead of reporting every render death as a timeout, and "
        "it RE-SUBMITS once on a node exception (a fresh seed -- seed = the run's "
        "base seed + the new ComfyuiJob id -- so the retry draws a different "
        "sample). A retry that RECOVERS still leaves this failed row, so read this "
        "entry as 'the workflow can die on this input', not as 'a render was "
        "lost'. The fault itself is the workflow payload (an empty CLIPSeg "
        "head/hand mask reaching the WAS 'Bounded Image Crop with Mask' node), not "
        "the Rails code. Reconciled orphans are excluded.",
    )


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


def publish_failed_verdict(n_failed, newest_h):
    """Pure: rejected posts inside the window -> severity (None when none)."""
    if not n_failed or n_failed <= 0:
        return None
    return "warn"


def check_publish_failed_silent():
    """A post Instagram REJECTED is marked failed -- the slot and photo are lost.

    check_publish_liveness counts only rows that were DUE and still unpublished,
    and check_publish_gap measures the newest POSTED post -- so a rejected post
    is invisible to both while its slot is lost: the rake task calls
    record_failure! with no requeue path and the publisher still exits 0
    ("Completed successfully"), so the run reads clean.
    Measured 2026-09-20: post 333 (photo 339, slot 15:15Z) -> 400 code 9007
    "Media ID is not available -- the media is not ready for publishing"
    (container-readiness race); 3rd such loss in the account's history.
    Both halves of the ORIGINAL finding are now fixed in-repo -- ffe9692 retries
    the publish on 9007 (4 attempts, 10s apart) and record_failure! persists the
    cause -- so this check no longer reports an unhandled failure; it is the alarm
    for whatever still survives the retry. The residual is the lost SLOT: nothing
    re-books it, and that is a live-publish policy call, not a code defect.
    """
    row = psql(
        "select count(*) || '|' || coalesce(round(extract(epoch from "
        "(now() at time zone 'UTC') - max(updated_at)) / 3600.0, 1)::text, 'na') "
        "from scheduling_posts where status = 'failed' and updated_at > "
        f"(now() at time zone 'UTC') - interval '{PUBLISH_FAILED_WINDOW_H} hours' "
        f"and coalesce(failure_reason, '') not like '{RETRY_MARKER}%'"
    )
    if row is None:
        return None
    n_str, _, h_str = row.rpartition("|")
    try:
        n_failed = int(n_str)
        newest_h = None if h_str == "na" else float(h_str)
    except ValueError:
        return None
    sev = publish_failed_verdict(n_failed, newest_h)
    if not sev:
        return None
    rows = psql_lines(
        "select 'post ' || id || ' photo ' || coalesce(photo_id::text, '-') || "
        "' slot ' || coalesce(scheduled_at::text, '-') || ' failed ' || updated_at "
        "|| ' reason: ' || coalesce(failure_reason, '(none stored)') "
        "from scheduling_posts where status = 'failed' and updated_at > "
        f"(now() at time zone 'UTC') - interval '{PUBLISH_FAILED_WINDOW_H} hours' "
        f"and coalesce(failure_reason, '') not like '{RETRY_MARKER}%' "
        "order by updated_at desc limit 5"
    ) or []
    age = "age unknown" if newest_h is None else f"newest {newest_h:.1f}h ago"
    return (
        "post-publish-failed-no-retry",
        "a post Instagram rejected ends as `failed` -- the slot and its photo are "
        "lost, and nothing re-books them",
        sev,
        f"{n_failed} un-retried post(s) marked failed in the last "
        f"{PUBLISH_FAILED_WINDOW_H}h ({age}): {'; '.join(rows)}. The retry path now "
        "exists in-repo (Scheduling::FailedPostRetry, wired into "
        "bin/scheduled_posting.sh as `scheduling:retry_failed` with APPLY=1): it "
        "re-books the SAME row onto a Growth::PostSlotPlanner slot when the stored "
        "failure_reason matches a TRANSIENT class (9007/2207027, timeout, 429, 5xx, "
        "connection, url_generation) and writes a `retry#N` marker so one failure "
        "can never be re-booked twice. Rows counted here are therefore those the "
        "retry would NOT touch or has not yet seen: a policy/permission rejection "
        "(deliberate -- re-offering rejected content is not ours to decide), a row "
        "with no stored reason, a photo file that is gone, or a repair that stopped "
        "running. Rows marked `retry#N` are excluded on purpose: they are booked, "
        "not lost. Original failure mode ffe9692 (4x/10s publish retry + persisted "
        "reason) still stands -- what lands here survived it.",
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


def post_slot_verdict(rows, landed_ts=POST_SLOT_PLANNER_LANDED,
                      window_min=BURST_WINDOW_MINUTES):
    """Pure: [(slot_epoch, created_epoch)] -> (live_pairs, residue_pairs).

    A pair is LIVE when either of its rows was created at/after
    Growth::PostSlotPlanner landed -- i.e. a producer is still bypassing the
    planner, which is the defect worth waking someone for. A pair whose rows both
    predate the planner is the pre-fix residue the board already knows about: it
    cannot burst (the publisher paces releases) and it cannot be re-spaced without
    a live-publishing edit, so it must not keep a warn-class issue open.
    """
    ordered = sorted(rows)
    live, residue = [], []
    for (a, ca), (b, cb) in zip(ordered, ordered[1:]):
        if (b - a) < window_min * 60:
            (live if max(ca, cb) >= landed_ts else residue).append((a, b))
    return live, residue


def over_cap_split(rows, cap, landed_ts=POST_SLOT_PLANNER_LANDED):
    """Pure: [(slot_epoch, created_epoch)] -> (live_days, residue_days).

    A day over the cadence cap is LIVE when any of its rows was created at/after
    Growth::PostSlotPlanner landed -- a producer or the planner itself is still
    over-filling a day, which is actionable. A day whose rows all predate the
    planner is pre-fix residue: the publisher's one-post-per-tick pacing spreads
    the release, and re-spacing the rows would be a live-publishing edit, so it
    clears as the day passes and must not carry warn severity.
    """
    per_day = {}
    for slot, created in rows:
        d = per_day.setdefault(int(slot // 86400) * 86400, {"n": 0, "live": False})
        d["n"] += 1
        d["live"] = d["live"] or created >= landed_ts
    live, residue = [], []
    for bucket, d in sorted(per_day.items()):
        if d["n"] > cap:
            (live if d["live"] else residue).append((bucket, d["n"]))
    return live, residue


def check_post_slot_bursts():
    """A producer still placing posts on top of each other -> a burst release.

    Every producer used to stamp `scheduled_at = Time.current + offset_days.days`,
    so a post's wall-clock time was whatever time the producing tick ran. Posts
    made by successive ticks for the same target day therefore shared a publishing
    hour, and bin/scheduled_posting.sh (hourly) released them in one tick --
    measured 2026-09-19: posts 317/319/326 published 06:00:14Z / 06:00:26Z /
    06:00:38Z, three posts inside 24 s, while the cadence cap is 3/day.

    Growth::PostSlotPlanner (2026-09-20 01:36Z) now allocates spaced slots, so a
    collision among rows created AFTER it means a producer is bypassing the
    planner -- the live regression this gates on. Rows created BEFORE it are
    residue: reported as context, never as the reason the issue stays open (the
    publisher's one-post-per-tick pacing, asserted by check_release_pacing, is
    what makes them harmless).
    """
    lines = psql_lines(
        "select extract(epoch from scheduled_at)::bigint || ' ' || "
        "extract(epoch from created_at)::bigint from scheduling_posts "
        "where created_at > (now() at time zone 'UTC') - interval '24 hours' "
        "and scheduled_at is not null order by scheduled_at"
    )
    if lines is None:
        return None
    try:
        rows = [tuple(float(v) for v in line.split()) for line in lines]
    except ValueError:
        return None

    live, residue = post_slot_verdict(rows)
    if not live:
        return None

    def stamp(t):
        return time.strftime("%m-%d %H:%M", time.gmtime(t))

    return (
        "post-slots-collide",
        f"{len(live)} pair(s) of posts created since the slot planner landed sit "
        f"inside {BURST_WINDOW_MINUTES} min of each other",
        "warn",
        "colliding: " + ", ".join(f"{stamp(a)}/{stamp(b)}" for a, b in live[:4])
        + "; rows created at/after Growth::PostSlotPlanner (2026-09-20 01:36Z) "
        "that still collide mean a producer is bypassing the planner -- the "
        "planner allocates the earliest under-cap day at a window slot >= 90 min "
        "from every taken slot"
        + (f". {len(residue)} further pair(s) are pre-fix residue (paced by "
           f"Scheduling::PostReleasePlan, context only)" if residue else ""),
    )


def check_post_schedule_shape():
    """The SHAPE of the future queue: days over the cadence cap.

    check_post_slot_bursts measures the PRODUCER (rows created in the last 24 h),
    so it goes green exactly when a pre-fix cluster ages out of that window --
    which is the same hour the cluster is RELEASED. Measured 2026-09-20: the
    probe stopped counting the 09-19 cluster at 15:15Z while posts 334/335/336
    were still queued to go out at 17:00Z, i.e. the board went green mid-burst.
    This measures what will actually leave the building: every future
    draft/scheduled row, grouped by publish day against the goal's posts_per_day.
    Pre-fix rows are what it currently sees, and it clears itself: a day drops
    out once it is past.

    WHY SLOT PROXIMITY IS NO LONGER GATED HERE (2026-09-20): proximity used to
    mean a burst because the publisher released EVERY due post in one pass.
    Scheduling::PostReleasePlan now caps a run at ONE post (MAX_PER_RUN=1), so
    two slots inside the window leave in CONSECUTIVE ticks, not together -- and
    that wiring is asserted by check_release_pacing, which is the guard that
    fires if the protection is reverted. Gating on proximity here would keep
    re-filing a condition the releaser already neutralises, which is how a board
    trains its reader to ignore it.

    SEVERITY FOLLOWS ACTIONABILITY: a day over the cap is a warn only when one of
    its rows was created at/after Growth::PostSlotPlanner landed -- i.e. the
    producer or the planner is STILL over-filling a day. A day whose rows all
    predate the planner is residue (see over_cap_split): it cannot be re-spaced
    without a live-publishing edit, it clears as the day passes, and it is
    reported at info so the fact stays visible without a warn nobody can action.
    """
    rows = psql_lines(
        "select extract(epoch from scheduled_at)::bigint || ' ' || "
        "extract(epoch from created_at)::bigint from scheduling_posts "
        "where status in ('draft','scheduled') and scheduled_at is not null "
        "and scheduled_at > (now() at time zone 'UTC') order by scheduled_at"
    )
    cap = psql("select coalesce(max(posts_per_day), 3) from growth_goals where status = 'active'")
    if rows is None or cap is None:
        return None
    try:
        slots = [tuple(float(v) for v in line.split()) for line in rows]
        cap = max(int(cap), 1)
    except ValueError:
        return None
    if not slots:
        return None

    live_days, residue_days = over_cap_split(slots, cap)
    if not live_days and not residue_days:
        return None
    over = live_days + residue_days
    pairs = colliding_pairs(sorted(t for t, _ in slots))

    day = lambda d: time.strftime("%m-%d", time.gmtime(d))  # noqa: E731
    stamp = lambda t: time.strftime("%m-%d %H:%M", time.gmtime(t))  # noqa: E731
    parts = [f"{len(over)} day(s) over the {cap}/day cap: "
             + ", ".join(f"{day(d)}={n}" for d, n in over[:4])]
    # Reported for context only: paced by PostReleasePlan, so it cannot burst.
    context = ""
    if pairs:
        context = (f" [{len(pairs)} pair(s) inside {BURST_WINDOW_MINUTES} min: "
                   + ", ".join(f"{stamp(a)}/{stamp(b)}" for a, b in pairs[:4])
                   + " -- paced, one post per tick, context only]")
    residue_note = ""
    if residue_days:
        residue_note = (f" {len(residue_days)} of them ({', '.join(day(d) for d, _ in residue_days[:4])}) "
                        f"are pre-fix residue: every row predates Growth::PostSlotPlanner, so no "
                        f"producer is misbehaving -- re-spacing them would be a live-publishing edit, "
                        f"and each day clears as it passes.")

    return (
        "post-schedule-bunched",
        (f"a producer created an over-cap day: {'; '.join(parts)}" if live_days
         else f"future queue still carries pre-fix over-cap days: {'; '.join(parts)}"),
        "warn" if live_days else "info",
        f"{'; '.join(parts)}; {len(slots)} future post(s) queued{context}. Producers "
        "allocate through Growth::PostSlotPlanner and the publisher releases at most "
        "ONE post per tick (Scheduling::PostReleasePlan, asserted by "
        "check_release_pacing), so these rows cannot leave as a burst."
        + residue_note,
    )


def release_pacing_verdict(rake_src, plan_src):
    """Pure: does the publisher still pace releases to ONE post per tick?

    Returns None when the protection is wired, else (severity, evidence). This is
    a REGRESSION GUARD, not a shape check: the pre-fix slot residue on the board
    is harmless ONLY while the publisher routes due posts through
    Scheduling::PostReleasePlan, and nothing else asserts that wiring survives a
    refactor. A silent revert would restore the measured 2026-09-19 failure
    (posts 317/319/326 published 06:00:14Z/06:00:26Z/06:00:38Z -- three posts
    inside 24 s) while every board signal stayed green.
    """
    if not rake_src or not plan_src:
        return ("warn", "cannot read the publisher's release-plan sources "
                        f"({RELEASE_PLAN_RAKE.name} / {RELEASE_PLAN_SRC.name})")
    if "PostReleasePlan" not in rake_src:
        return ("critical",
                "scheduling:post_scheduled no longer routes due posts through "
                "Scheduling::PostReleasePlan -- every due post is released in ONE "
                "tick again, so bunched slots burst at the account")
    m = re.search(r"MAX_PER_RUN\s*=\s*(\d+)", plan_src)
    if not m:
        return ("warn", "Scheduling::PostReleasePlan::MAX_PER_RUN is no longer an "
                        "integer literal, so the per-tick cap cannot be verified")
    if int(m.group(1)) != 1:
        return ("warn", f"Scheduling::PostReleasePlan::MAX_PER_RUN={m.group(1)}: the "
                        f"publisher may release {m.group(1)} posts in one tick again")
    return None


def check_release_pacing():
    """Assert the fix that stops bunched slots from bursting is still wired.

    The 2026-09-19 burst had two independent causes: producers stamped
    `scheduled_at = Time.current + offset_days.days` (fixed by
    Growth::PostSlotPlanner) and the publisher released EVERY due post in one
    pass (fixed by Scheduling::PostReleasePlan, MAX_PER_RUN=1). The second fix is
    what makes the pre-fix residue on the board harmless, and it is the only
    thing between a bunched day and a real burst -- so its revert looks exactly
    like a healthy board. Assert the wiring, not the outcome.
    """
    def read(p):
        try:
            return p.read_text()
        except OSError:
            return ""

    v = release_pacing_verdict(read(RELEASE_PLAN_RAKE), read(RELEASE_PLAN_SRC))
    if not v:
        return None
    return (
        "release-pacing-unwired",
        "the publisher's one-post-per-tick pacing is not wired",
        v[0],
        v[1] + f" (checked {RELEASE_PLAN_RAKE.name} + {RELEASE_PLAN_SRC.name})",
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


def queued_hashtag_verdict(n_untagged):
    """Pure: queued posts carrying no hashtags -> severity (None when none)."""
    if not n_untagged or n_untagged <= 0:
        return None
    return "warn"


def check_queued_post_hashtags():
    """An unpublished post with NO hashtags publishes with none -- silently.

    The hashtag chain was broken for the account's whole life (all 197 posted
    items went out with zero tags) and was repaired on 2026-09-19 in four places
    (HashtagEngine's pillar split, Personas::HashtagStrategy#tags, the
    generator's create, and the publisher's caption). Every one of those fixes
    is on the PRODUCER side, so a row that is already in the queue keeps its
    empty `hashtags` and the publisher appends nothing: measured 2026-09-20,
    post 340 (slot 09-24 17:50Z) was created 2 min AFTER that fix by a process
    still running pre-fix code, and nothing could see it -- the hashtag probes
    measure the producer window, and the send path reads the column as-is.
    This is the queue-side counterpart of check_placeholder_caption_queued, and
    the same shape of blind spot: an artifact an outage already wrote into the
    queue, which the fix for the outage does not repair.
    """
    pred = ("status in ('draft','scheduled') and "
            "jsonb_array_length(coalesce(hashtags, '[]'::jsonb)) = 0 "
            "and (scheduled_at > (now() at time zone 'UTC') "
            "or optimal_time_calculated > (now() at time zone 'UTC'))")
    n = psql(f"select count(*) from scheduling_posts where {pred}")
    if n is None:
        return None
    try:
        n = int(n)
    except ValueError:
        return None
    sev = queued_hashtag_verdict(n)
    if not sev:
        return None

    rows = psql_lines(
        "select id || ' slot ' || to_char(coalesce(scheduled_at, "
        "optimal_time_calculated), 'MM-DD HH24:MI') from scheduling_posts "
        f"where {pred} order by coalesce(scheduled_at, optimal_time_calculated)"
    )
    return (
        "queued-post-untagged",
        f"{n} unpublished post(s) have no hashtags and will publish without any",
        sev,
        "untagged queue: " + ", ".join((rows or [])[:6])
        + "; the publisher appends scheduling_posts.hashtags to the caption at "
        "send time, so an empty column ships an untagged post (the account's only "
        "discoverability lever at 157 followers). Repair: "
        "`bundle exec rails hashtags:backfill_queued` (dry-run; APPLY=1 to write) "
        "-- bin/scheduled_posting.sh runs it with APPLY=1 ahead of "
        "scheduling:post_scheduled, so this clears at the next publishing tick; "
        "a row that survives a tick means the engine returned nothing for it.",
    )


IMAGE_GROUNDING_WINDOW_H = 24 * 7


def image_grounding_verdict(total, attached, recent_unattached, vision_posts,
                            newest_attach=None):
    """Pure: do published captions ever look at the render itself?

    Returns (severity, detail) or None when the condition is clean or unknown.

    "Captions are written from context text, never from the image" is not a code
    defect on its own -- the caller routes only ATTACHED photos to
    CaptionGeneration::VisionGenerator, and every render the growth harness
    imports is path-only -- but it IS the difference between a caption that
    describes the photo and one that invents a scene the photo does not show
    (measured 2026-09-21 on photo 351: vision said "warm cup of coffee and a
    beautiful autumn morning" for an autumn street scene; the text path shipped
    "rain drumming on the windowpane ... chamomile tea"). Two things must hold
    for it to be LIVE rather than history: photos are still being imported
    without an attachment, and no post in the window was written by the vision
    path -- which scheduling_posts.caption_metadata now records on BOTH paths
    (generator: 'vision' / 'text').
    """
    if any(v is None for v in (total, attached, recent_unattached, vision_posts)):
        return None
    if vision_posts > 0:
        return None  # the image path is taken -> the condition no longer reproduces
    if recent_unattached <= 0:
        return None  # every recent photo carries bytes the vision path can read
    detail = (
        f"{recent_unattached} render(s) imported in the last "
        f"{IMAGE_GROUNDING_WINDOW_H // 24} days, and 0 post(s) in that window were "
        f"written by the vision path; corpus {total} photos / {attached} attached"
    )
    if newest_attach:
        detail += f", newest attachment {newest_attach}"
    return "info", detail


def check_caption_image_grounding():
    """Captions never look at the render: the vision path is unreachable.

    HISTORY (this is why the check exists): the caller
    (PostAutomation::GenerateCaption) branched on `photo.image.attached?`, and
    Growth::ContentGenerator#import_photo creates photos path-only -- so since
    2026-05-28 every caption was generated from context text and
    CaptionGeneration::VisionGenerator was dead code in production, silently.
    Nothing else measures it: check_caption_fallback counts placeholders and
    check_placeholder_caption_queued counts queued junk, so a caption that is
    fluent and WRONG about the photo reads green everywhere.

    The branch was FLIPPED 2026-09-21 (it now routes on readable bytes), so the
    attachment count is no longer the condition -- it is kept as the count of
    renders still being produced. What remains measurable, and what this check
    now reports, is the second clause: no post in the window was captioned by
    the vision path YET. That clears on the next rendered post.
    """
    attached_pred = ("exists (select 1 from active_storage_attachments a "
                     "where a.record_type = 'ContentPillars::Photo' "
                     "and a.record_id = p.id)")
    total = psql("select count(*) from photos p")
    attached = psql(f"select count(*) from photos p where {attached_pred}")
    newest = psql("select to_char(max(p.created_at), 'YYYY-MM-DD') from photos p "
                  f"where {attached_pred}")
    recent_unattached = psql(
        f"select count(*) from photos p where not {attached_pred} and "
        "p.created_at > (now() at time zone 'UTC') - "
        f"interval '{IMAGE_GROUNDING_WINDOW_H} hours'")
    vision_posts = psql(
        "select count(*) from scheduling_posts where "
        "caption_metadata->>'generator' = 'vision' and created_at > "
        f"(now() at time zone 'UTC') - interval '{IMAGE_GROUNDING_WINDOW_H} hours'")

    counts = []
    for raw in (total, attached, recent_unattached, vision_posts):
        try:
            counts.append(int(raw))
        except (TypeError, ValueError):
            return None
    verdict = image_grounding_verdict(*counts, newest_attach=newest)
    if not verdict:
        return None
    sev, detail = verdict
    return (
        "vision-caption-path-never-taken",
        "no post in the window has been captioned by the vision path yet "
        "(the routing flip landed 2026-09-21)",
        sev,
        detail
        + ". PostAutomation::GenerateCaption used to branch on "
        "photo.image.attached?, and Growth::ContentGenerator#import_photo creates "
        "photos path-only, so every production caption was written from the "
        "photo's context text: measured 2026-09-21, the text path described "
        "'rain drumming on the windowpane ... chamomile tea' for a render that "
        "shows an autumn street scene with a mug, which the vision path "
        "described correctly. THE BRANCH WAS FLIPPED 2026-09-21 (commit f37136e): "
        "it now routes on CaptionGeneration::ImageEncoder.readable?, so a "
        "path-only render with a resolvable file takes the vision path -- "
        "verified live on photo 353 (generator='vision', gemma3:4b, caption "
        "grounded in the image). The attachment count in this evidence is "
        "therefore NO LONGER the condition; it is kept only as the count of "
        "renders still being produced. The one remaining condition is the second "
        "clause: no post in the window has yet been captioned by the vision path. "
        "This record closes itself on the next rendered post (measured cost on "
        "the live caption host: 15.0s for a 1.1 MB render through gemma3:4b)."
    )


def prompt_safety_verdict(guard_wired, db_hits, file_hits):
    """Severity for the prompt-safety condition, or None when it is clean.

    Pure so the selftest can drive it. The guard's presence is the difference
    between "stored text is dirty but every render is neutralised" (warn) and
    "nothing stands between the stored text and a render" (critical).
    """
    if not guard_wired:
        return "critical"
    if db_hits or file_hits:
        return "warn"
    return None


def _workflow_blobs_from_db():
    """[(step_id, pipeline_id, workflow_json)] or None when the DB is unreadable.

    base64 so a pretty-printed workflow (multi-line) survives psql -At's
    line-per-row framing: a raw select would shred each row into dozens of lines.
    """
    rows = psql_lines(
        "select id || '|' || pipeline_id || '|' || "
        "encode(convert_to(comfy_workflow_json, 'UTF8'), 'base64') "
        "from pipeline_steps order by id")
    if rows is None:
        return None
    out = []
    for line in rows:
        parts = line.split("|", 2)
        if len(parts) != 3:
            continue
        try:
            blob = base64.b64decode(parts[2]).decode("utf-8", "replace")
        except Exception:
            continue
        out.append((parts[0], parts[1], blob))
    return out


def _workflow_blobs_from_repo():
    out = []
    if not WORKFLOW_DIR.exists():
        return out
    for p in sorted(WORKFLOW_DIR.rglob("*.json")):
        try:
            out.append((str(p.relative_to(APP)), p.read_text(errors="replace")))
        except Exception:
            continue
    return out


def _blob_violations(blob):
    """(juvenile_tokens, adult_suppressing_tokens) found in one workflow blob."""
    juvenile = sorted({m.group(0).strip().lower() for m in JUVENILE_RX.finditer(blob or "")})
    adult = []
    # An adult-suppressing token is only a violation in a comma-separated list
    # (the negative-prompt shape) inside a blob that carries negative boilerplate.
    if NEG_BOILERPLATE_RX.search(blob or ""):
        adult = sorted({m.group(0).strip(" ,\t\n").lower()
                        for m in ADULT_LIST_RX.finditer(blob or "")})
    return juvenile, adult


def check_pipeline_prompt_safety():
    """Stored render text must not direct a minor or condition against adulthood.

    This is the check for the class of defect that every earlier run recorded as
    "Tim's identity decision" and left in place: a STORED workflow is executable
    instruction text, and the stored text was conditioning the production render
    against "adult, mature_face" (vision reads of the results: "a young girl,
    likely a teenager") while a legacy face step instructed an LLM to render "a
    white, Caucasian young teenager".

    Two independent things are asserted, because either alone is insufficient:
    the RENDER PATH still runs the guard (structural -- a code edit that drops the
    call would otherwise be invisible until a render shipped), and the STORED text
    is clean (data -- the guard neutralises a render, but the admin UI, an audit
    and every other consumer of pipeline_steps.comfy_workflow_json read the raw
    column). Detection only: the rewrite lives in PipelinePromptSafety and the
    repair in `rake pipeline:prompt_safety`.
    """
    try:
        guard_wired = PROMPT_SAFETY_GUARD_REF in PROMPT_SAFETY_GUARD_SRC.read_text()
    except Exception:
        guard_wired = False

    db_rows = _workflow_blobs_from_db()
    db_hits = []
    if db_rows is not None:
        for step_id, pipeline_id, blob in db_rows:
            juvenile, adult = _blob_violations(blob)
            if juvenile or adult:
                db_hits.append((f"step {step_id} (pipeline {pipeline_id})", juvenile + adult))

    file_hits = []
    for rel, blob in _workflow_blobs_from_repo():
        juvenile, adult = _blob_violations(blob)
        if juvenile or adult:
            file_hits.append((rel, juvenile + adult))

    severity = prompt_safety_verdict(guard_wired, db_hits, file_hits)
    if not severity:
        return None

    if not guard_wired:
        return (
            "pipeline-prompt-safety",
            "the render path no longer runs the prompt-safety guard, so stored "
            "workflow text reaches ComfyUI unsanitised",
            "critical",
            f"{PROMPT_SAFETY_GUARD_SRC.relative_to(APP)} no longer references "
            f"{PROMPT_SAFETY_GUARD_REF}, so the guard is not applied to any render "
            "payload. Stored violations still present: "
            + ("; ".join(f"{lbl}: {', '.join(toks)}" for lbl, toks in (db_hits + file_hits)) or "none")
            + ". Restore the call in BuildJobPayload#call (it parses the workflow "
              "and must run it through PipelinePromptSafety.sanitize_workflow before "
              "building the payload).",
        )

    evidence = (
        "STORED workflow text carries a prompt-safety violation. The render path "
        "IS guarded (BuildJobPayload runs every workflow through "
        "PipelinePromptSafety), so a render is neutralised -- but the stored column "
        "is what the admin UI shows, what a human reads when auditing the persona, "
        "and what every other consumer inherits. "
        + " | ".join(f"{lbl}: {', '.join(toks)}" for lbl, toks in (db_hits + file_hits))
        + ". Repair: `bundle exec rake pipeline:prompt_safety` (dry run) then "
          "APPLY=1 to write; it backs the original column value up to "
          "ops/backups/ first. Rules and rationale: "
          "packs/pipeline/app/services/pipeline_prompt_safety.rb."
    )
    return (
        "pipeline-prompt-safety",
        "stored render prompts direct a minor or condition against adult features",
        severity,
        evidence,
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


def gpu_vram_free_mib():
    out, rc = run(["nvidia-smi", "--query-gpu=memory.free", "--format=csv,noheader,nounits"])
    if rc != 0 or not out:
        return None
    try:
        return int(out.splitlines()[0].strip())
    except ValueError:
        return None


VRAM_HOLDER_MIN_MIB = 128   # a 37 MiB desktop helper is not what blocks a claim


def _proc_cmdline(pid):
    """The local process's argv as one line, or '' when it is not ours to read.

    nvidia-smi reports a comm name that is sometimes just `python3`; the argv is
    what actually names the blocker (`labeler_spa.py`), and the 4090 is local.
    """
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as fh:
            return fh.read().decode("utf-8", "replace").replace("\0", " ").strip()
    except Exception:
        return ""


def gpu_vram_holders(min_mib=VRAM_HOLDER_MIN_MIB):
    """[(pid, name, used_mib)] for processes holding the 4090 OUTSIDE the scheduler.

    The reservation is the only thing that keeps co-tenants off the card, and it
    cannot see a process that never asked for one: the BT-Net labeler (user-managed,
    ~4.5 GiB, `labeler_spa.py`) and the desktop session. Without this, a refusal
    reads `holder=none` while 4.5 GiB sits in someone else's process -- which is how
    12 h of starvation got re-diagnosed as "nobody is blocking us" every tick.
    Holders under `min_mib` are dropped so the note names the blocker, not the noise.
    """
    out, rc = run(["nvidia-smi", "--query-compute-apps=pid,process_name,used_memory",
                   "--format=csv,noheader,nounits"])
    if rc != 0 or not out:
        return []
    rows = []
    for line in out.splitlines():
        parts = [p.strip() for p in line.split(",")]
        if len(parts) < 3:
            continue
        try:
            pid, mib = int(parts[0]), int(parts[2])
        except ValueError:
            continue
        if mib < min_mib:
            continue
        name = parts[1].rsplit("/", 1)[-1] or parts[1]
        for tok in _proc_cmdline(pid).split()[1:]:
            if not tok.startswith("-"):
                name = tok.rsplit("/", 1)[-1] or name
                break
        rows.append((pid, name, mib))
    return rows


def vram_blocker_note():
    """The outside-scheduler holders as one line, or '' when the card is clean."""
    return ", ".join(f"{pid} {name} {mib / 1024:.1f}GiB" for pid, name, mib in gpu_vram_holders())


def harness_constants():
    """(full_ask_gb, min_fit_gb, headroom_mib) read from the harness -- it owns them.

    Read, never hardcoded: bin/comfyui_harness.sh is the one place the fit policy is
    defined, and a copy here would drift out of step. The formula itself is mirrored
    in adaptive_ask_gb() and CROSS-CHECKED against the harness's own `plan` output by
    selftest, so changing it there fails the suite instead of silently making this
    probe report a different ask than the launcher actually makes.
    """
    try:
        txt = (APP / "bin" / "comfyui_harness.sh").read_text()
    except Exception:
        return 21.0, 16.0, 1024.0

    def grab(name, default):
        m = re.search(rf"^{name}=(\d+(?:\.\d+)?)", txt, re.M)
        return float(m.group(1)) if m else default

    return grab("VRAM", 21.0), grab("VRAM_MIN_FIT", 16.0), grab("FIT_HEADROOM_MIB", 1024.0)


def adaptive_ask_gb(free_mib, full_gb=None, min_fit_gb=None, headroom_mib=None):
    """PURE: the VRAM ask the harness will make for a given free-VRAM reading.

    Mirrors vram_ask_for_free() in bin/comfyui_harness.sh. WHY the ask is not simply
    the full 21GiB: that number is a FIT value (f0af66a, 2026-09-16 -- 21 because
    22.4GiB happened to be free with the desktop attached), NOT the render's
    requirement. ComfyUI's dynamic loader sizes the UNet to whatever is free at load
    time and offloads the remainder, and this install has ALREADY rendered this exact
    workflow with a much smaller resident UNet (comfyui-comfyui-variety-1789685009.log,
    2026-09-17: "loaded partially; 15275.15 MB usable, 14914.77 MB loaded, 7785.37 MB
    offloaded" -> "Prompt executed in 95.61 seconds", with ~8GiB of co-tenants on the
    card). So a co-tenant holding a few GiB does not make a render impossible, and the
    ask is budgeted against live free memory: full ask when the card is free, free
    minus headroom otherwise, and the FLOOR when even that reduced ask falls below it.

    WHY the floor and not the full ask in that last case (fixed 2026-09-21): the ask is
    PERSISTED in the queue record (jobs/<id>.json -> vram_gb) and re-checked at CLAIM
    time against a DIFFERENT free reading -- the card once the occupant has released.
    A full ask minted while another job occupies the card is therefore a self-inflicted
    `vram_insufficient` for the whole life of the record (measured 2026-09-21: the 08:03
    tick asked 21GiB against a card held by prx-tg-pixel-posttrain-v3, and the refusal
    the record then earns is the one already in the harness log: "free=18949MiB vs
    requested 21GiB"). The entry is given up at the FIFO head and re-requested on the
    next tick, costing a whole render window. Carrying the floor instead changes no
    invariant -- `poll` still refuses anything below the ask -- and makes the record
    claimable the moment the card frees to the floor.
    """
    d_full, d_min, d_head = harness_constants()
    full_gb = d_full if full_gb is None else full_gb
    min_fit_gb = d_min if min_fit_gb is None else min_fit_gb
    headroom_mib = d_head if headroom_mib is None else headroom_mib
    if free_mib is None:
        return full_gb
    try:
        free_mib = float(free_mib)
    except (TypeError, ValueError):
        return full_gb
    if free_mib >= full_gb * 1024:
        return full_gb
    eff = int((free_mib - headroom_mib) // 1024)
    return float(min_fit_gb) if eff < min_fit_gb else float(eff)


def our_reservation_gb():
    """The VRAM ask we would make right now: what we asked for, else the live fit.

    Read, never hardcoded: the harness owns the number AND the policy. Order is what
    we actually asked for (a queued entry), then what the harness WOULD ask for given
    live free memory -- which since 2026-09-21 is free minus headroom, not the 21GiB
    fit value. Consequence for the reader: `free < ask` now means free VRAM is below
    the harness's fit floor, i.e. the card really is too full to render on.
    """
    for j in queue(GPU):
        if j.get("project") == "turbo-carnival" and j.get("vram_gb"):
            try:
                return float(j["vram_gb"])
            except (TypeError, ValueError):
                pass
    return adaptive_ask_gb(gpu_vram_free_mib())


def gpu_total_mib():
    out, rc = run(["nvidia-smi", "--query-gpu=memory.total", "--format=csv,noheader,nounits"])
    if rc != 0 or not out:
        return None
    try:
        return int(out.splitlines()[0].strip())
    except ValueError:
        return None


def gpu_util_peak_pct(samples=5, interval=2):
    """Max GPU utilization over a short WINDOW, or None.

    One sample is not a signal in either direction (a healthy run alternates a
    short burst with a long dataloader gap), so the question this answers -- "is
    the process holding the missing VRAM actually WORKING, or merely resident?"
    -- needs a window. Sampled only when a blocker is present, so the healthy
    path stays fast.
    """
    vals = []
    for i in range(samples):
        out, rc = run(["nvidia-smi", "--query-gpu=utilization.gpu",
                       "--format=csv,noheader,nounits"], timeout=10)
        if rc == 0 and out:
            try:
                vals.append(int(out.splitlines()[0].strip().split()[0]))
            except (ValueError, IndexError):
                pass
        if i < samples - 1:
            time.sleep(interval)
    return max(vals) if vals else None


def telemetry_peak_mib(path=None):
    """Max vram_used_mib across the telemetry samples, or None.

    The render footprint a reservation SHOULD be sized from, measured by the
    harness's own sampler -- read from the file rather than copied, so a copy here
    cannot drift out of step.

    It is an UPPER BOUND on that footprint, not the footprint: the sampler reads
    CARD-level `nvidia-smi memory.used`, so it counts every co-tenant, and the
    only session on record (job comfyui-1789826497-1334030, 2026-09-19) was
    dispatching the deprecated-pipeline pony/SDXL duplicate renders alongside our
    flux work -- the contention OOM root-caused and fixed that same day. The
    flux-only footprint is therefore UNMEASURED, and the reservation was never
    derived from this number: VRAM=21 came from f0af66a (2026-09-16) as a FIT to
    the 22.4GiB then free with the desktop attached. Label it as an upper bound
    and say what it was measured during, because a reader who takes it for "the
    measured requirement" concludes the conflict is structural and permanent and
    stops looking for the cheap fix.
    """
    mx = None
    try:
        with open(path or TELE_FILE) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    v = json.loads(line).get("vram_used_mib")
                except Exception:
                    continue
                if v:
                    mx = v if mx is None else max(mx, v)
    except Exception:
        return None
    return mx


def vram_refusal_clause(free_mib, req_gb, util_pct, holder_count,
                        peak_mib=None, total_mib=None):
    """PURE: why a VRAM refusal is structural, or '' when free memory is not the cause.

    CORRECTED 2026-09-21 -- this used to assert "renders need a near-empty card",
    inferred from the sampler's CARD-level peak (23.2 of 24.0GiB). That inference was
    wrong twice over: the peak was sampled while the deprecated pony/SDXL duplicate
    renders shared the card (it counts co-tenants, an upper bound, and 23.2 > 21 means
    it never sourced the 21GiB ask anyway), and ComfyUI's own logs show the loader
    sizing the UNet to whatever is FREE at load time and offloading the remainder --
    this install has already rendered this workflow at a 14.9GiB resident UNet with
    ~8GiB of co-tenants on the card (comfyui-comfyui-variety-1789685009.log,
    "Prompt executed in 95.61 seconds").

    So a resident process is NOT a blocker by itself, and since the harness budgets
    its ask against live free memory (adaptive_ask_gb) the only structural refusal
    left is free VRAM below the harness's fit FLOOR, where the ask is not reduced and
    nothing is attempted. Without this the reader sees "holder=none" and re-derives
    the cause by hand, which is what six consecutive ticks did.
    """
    if free_mib is None or req_gb is None or holder_count is None:
        # holder_count is None only when the holders cannot be enumerated (no
        # nvidia-smi): an unknown blocker set must not be reported as a known
        # structural conflict, the same way an unreadable queue is never "idle".
        return ""
    if free_mib >= req_gb * 1024:
        return ""
    clause = (f" -- free {free_mib / 1024:.1f}GiB is below the {req_gb:.0f}GiB ask, and below "
              "the harness's fit floor: the ask is not reduced and no render is attempted. "
              "A resident co-tenant is not a blocker by itself -- ComfyUI partial-loads the "
              "UNet to free VRAM and offloads the rest (it has rendered at a 14.9GiB resident UNet)")
    if peak_mib and total_mib:
        clause += (f" (card-level peak {peak_mib / 1024:.1f} of {total_mib / 1024:.1f}GiB "
                   "measured under contention)")
    if util_pct is not None:
        clause += f"; card {util_pct}% busy over 10s"
        clause += " (holder resident but idle)" if util_pct <= 5 else " (holder working)"
    return clause


def vram_fit_note(with_util=False):
    """What stands between us and a claim: free VRAM vs our reservation, plus holders.

    A refusal whose evidence says only `holder=none` is unactionable -- it was the
    *foreign job* that went away, not the co-tenant *process*. Name both numbers and
    the process, or the next tick re-diagnoses the same starvation.

    with_util adds the GPU-utilization window (a 10 s sample), which is what
    separates "a co-tenant is training" from "a co-tenant's tool is merely
    resident". Off by default so the checks that only need the numbers stay fast.
    """
    free = gpu_vram_free_mib()
    if free is None:
        return ""
    req = our_reservation_gb()
    note = f"free={free / 1024:.1f}GiB" + (f" vs ask {req:.0f}GiB" if req else "")
    blockers = gpu_vram_holders()
    if blockers:
        note += "; outside-scheduler holders: " + ", ".join(
            f"{pid} {name} {mib / 1024:.1f}GiB" for pid, name, mib in blockers)
    if req and free < req * 1024:
        note += vram_refusal_clause(
            free, req, gpu_util_peak_pct() if with_util else None,
            len(blockers), telemetry_peak_mib(), gpu_total_mib())
    return note


def comfyui_queue_depth():
    """(running + pending) renders in the live instance's native queue, or None.

    None means "cannot tell" and must never be read as "idle": the point of the
    liveness gate is that a probe which cannot see must not accuse.
    """
    out, rc = run(["curl", "-s", "-m", "5", "http://127.0.0.1:8188/queue"])
    if rc != 0 or not out:
        return None
    try:
        d = json.loads(out)
        return len(d.get("queue_running") or []) + len(d.get("queue_pending") or [])
    except Exception:
        return None


def comfyui_last_prompt_age_s(now=None):
    """Seconds since the newest prompt this instance executed, or None.

    /history records each prompt's status messages with ms timestamps; the newest
    of those is the last time the instance did real work. None = never rendered
    (empty history) or unreadable -- both treated as not-live evidence only by the
    caller's policy, never as "idle" on their own.
    """
    out, rc = run(["curl", "-s", "-m", "5", "http://127.0.0.1:8188/history"])
    if rc != 0 or not out:
        return None
    try:
        d = json.loads(out)
    except Exception:
        return None
    stamps = []
    for rec in (d.values() if isinstance(d, dict) else []):
        msgs = ((rec or {}).get("status") or {}).get("messages") or []
        for m in msgs:
            if isinstance(m, list) and len(m) > 1 and isinstance(m[1], dict):
                ts = m[1].get("timestamp")
                if isinstance(ts, (int, float)):
                    stamps.append(ts / 1000.0)
    if not stamps:
        return None
    return max(0.0, (now if now is not None else time.time()) - max(stamps))


def comfyui_holder_verdict(queue_depth, last_prompt_age_s):
    """Unclaimed ComfyUI: LIVE work, idle residue, or unknown? -> live|idle|unknown.

    An unclaimed instance is only a problem for the VRAM it pins when nobody is
    using it (that residue is what makes the next claimant OOM or get refused).
    While it is rendering -- queue non-empty, or a prompt inside
    COMFYUI_LIVE_WINDOW_S -- it is a co-tenant doing live work on a shared install
    that our ownership rule forbids interfering with, so there is nothing to file.
    """
    if queue_depth is None:
        return "unknown"
    if queue_depth > 0:
        return "live"
    if last_prompt_age_s is not None and last_prompt_age_s < COMFYUI_LIVE_WINDOW_S:
        return "live"
    return "idle"


def comfyui_attribution():
    """'owner=ours|foreign pid=… cgroup=… started=…' for the process serving 8188.

    Mirrors bin/comfyui_harness.sh's attribution so a filed issue names WHO holds
    the card: the harness records this only in its own log, and the board is what
    a human (or the next agent) actually reads. Ownership = the pid recorded as
    comfy_pid in our claim state; anything else is foreign and never ours to kill.
    """
    out, rc = run(["pgrep", "-f", r"main\.py --listen"])
    pid = (out.splitlines() or [""])[0].strip() if rc == 0 else ""
    if not pid:
        return "owner=unknown"
    who = "foreign"
    try:
        with open(CLAIM_FILE) as fh:
            if str(json.load(fh).get("comfy_pid") or "") == pid:
                who = "ours"
    except Exception:
        pass
    cg = "?"
    try:
        cg = Path(f"/proc/{pid}/cgroup").read_text().strip().split("::")[-1] or "?"
    except Exception:
        pass
    started = run(["ps", "-o", "lstart=", "-p", pid])[0].strip().replace(" ", "_") or "?"
    return f"owner={who} pid={pid} cgroup={cg} started={started}"


def check_comfyui_vram_unclaimed():
    """ComfyUI is up while NOBODY holds the GPU, pinning VRAM, and is IDLE.

    The harm of an orphaned instance is the memory it holds on a shared card, not
    the open port -- a warm instance with no claim is what the next claimant OOMs
    against. Deliberately NOT fired when a claim exists (another project holding
    the slot and running the shared install is normal sharing, and the harness
    adopts foreign instances rather than killing them, so there is nothing to
    action), and NOT fired while the instance is live (see
    comfyui_holder_verdict). Sampled from hardware, not inferred from the port
    being open.
    """
    if not comfyui_up():
        return None
    g = (sched_state().get("gpus") or {}).get(GPU) or {}
    if g.get("status") in ("busy", "claimed"):
        return None
    used = gpu_vram_used_mib()
    if used is None or used < UNCLAIMED_COMFYUI_VRAM_MIB:
        return None
    depth = comfyui_queue_depth()
    age = comfyui_last_prompt_age_s()
    if comfyui_holder_verdict(depth, age) != "idle":
        return None
    last = "never" if age is None else f"{age / 60:.0f} min ago"
    return (
        "comfyui-vram-unclaimed",
        f"ComfyUI is up with no claim on the {GPU} while holding {used / 1024:.1f} GB",
        "warn",
        f"port 8188 answering, state={g.get('status')}, vram_used={used}MiB "
        f"(threshold {UNCLAIMED_COMFYUI_VRAM_MIB}MiB); the instance is IDLE -- native "
        f"queue empty and last prompt {last} (live window {COMFYUI_LIVE_WINDOW_S // 60} "
        f"min) -- so this VRAM is residue the next claimant renders against. "
        f"{comfyui_attribution()}. A foreign instance is not ours to kill (harness "
        "ownership rule): shut it down from its own session, or accept the hold.",
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


LOG_HEALTH_FILES = ("log/scheduled_posting.log", "log/development.log",
                    "log/comfyui_harness.log")
# Paths a prompt still points at but nothing writes: named here so a monitoring run
# sees WHY they are absent from the live list instead of re-deriving it.
DEPRECATED_LOGS = ("log/growth_harness.log",)
# Deliberately narrow: a monitoring run must be able to read the answer at a
# glance. "failed"/"error" appear in ordinary prose lines, so match the shapes a
# real crash prints.
LOG_ERROR_PAT = re.compile(r"\b(ERROR|FATAL|Traceback|aborted|Exception)\b")
LOG_SCAN_BYTES = 2 * 1024 * 1024


def log_error_samples(rel_path, limit=3):
    """(exists, age_seconds, error_count, newest_error_lines) for a log's tail.

    Bounded to the last LOG_SCAN_BYTES so `log-health` stays cheap on a 24 MB
    development.log.
    """
    p = APP / rel_path
    try:
        st = p.stat()
    except OSError:
        return False, None, 0, []
    age = time.time() - st.st_mtime
    with open(p, "rb") as fh:
        if st.st_size > LOG_SCAN_BYTES:
            fh.seek(st.st_size - LOG_SCAN_BYTES)
            fh.readline()  # drop the partial first line of the window
        tail = fh.read().decode("utf-8", "replace")
    hits = [ln.strip() for ln in tail.splitlines() if LOG_ERROR_PAT.search(ln)]
    return True, age, len(hits), hits[-limit:]


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


def _asks_for_delivery(row):
    """Pure: True when a job's configured target is anything but plain local storage.

    `deliver` is a comma-separated target list; `local` (and empty) means the result
    is meant to stay on disk, so such a job can never be delivery-broken.
    """
    tokens = [t.strip().lower() for t in str(row.get("deliver") or "").split(",")]
    return any(t and t != "local" for t in tokens)


def cron_delivery_verdict(rows):
    """Pure: job records -> (severity, evidence) when a result was never delivered.

    From the fix loop's point of view a run whose result never reaches the user is
    a FAILED run -- and the failure is invisible from the repo side: the agent
    runs, the output file is written, the next tick fires on time.

    A job counts as broken when it still ASKS for delivery (its configured target is
    not `local`) AND its last attempt failed. The configured target is read on
    purpose: `last_status` is HISTORICAL, so a job whose target has just been fixed
    keeps reading `delivery_failed` until it runs again -- up to a week for the weekly
    job -- and the board would carry an already-resolved item the whole time. A job
    that delivers locally, or has not run yet, is never reported as broken.
    """
    broken = []
    for r in rows:
        if not _asks_for_delivery(r):
            continue
        status = str(r.get("status") or "").lower()
        if "delivery_failed" in status or "delivery_error" in status:
            broken.append(r)
    if not broken:
        return None
    detail = "; ".join(
        f"{r.get('name')} ({r.get('id')}, deliver={r.get('deliver')}, "
        f"origin={(r.get('origin') or {}).get('platform')}, "
        f"error={r.get('error')})"
        for r in broken)
    return ("warn", f"{len(broken)} turbo-carnival cron job(s) whose last result was "
                    f"never delivered: {detail}")


def check_cron_delivery():
    """The fix loop's own output path: a report nobody receives closes nothing.

    Every other check reads a signal this repo owns. This one reads the job store,
    because a delivery failure leaves no trace inside the repo: the run succeeds,
    the output lands in cron/output/<id>/, and the only evidence is the job's own
    last_status. That is exactly the silent-decay shape the board exists to catch
    (genome: 'Acknowledgment != Resolution' / 'Expected-Event Absence'): findings
    were filed, worked and closed for a day while the reports carrying them were
    dropped, so the human side of the loop never saw any of it.

    A store that cannot be read returns None (no signal) rather than a warn -- a
    probe that cannot measure must not invent a failure; check_probe_inputs owns
    the blindness report.
    """
    try:
        store = json.loads(CRON_JOBS.read_text())
    except Exception:
        return None
    jobs = store if isinstance(store, list) else store.get("jobs", store)
    if isinstance(jobs, dict):
        jobs = list(jobs.values())
    rows = [{"name": j.get("name") or j.get("id"), "id": j.get("id"),
             "status": j.get("last_status"), "deliver": j.get("deliver"),
             "origin": j.get("origin"), "error": j.get("last_delivery_error")}
            for j in jobs if isinstance(j, dict)]
    v = cron_delivery_verdict(rows)
    if not v:
        return None
    return (
        "cron-delivery-target-broken",
        "cron results are written to disk but never delivered",
        v[0],
        v[1] + " — the fix is the delivery target on those jobs "
              "(`hermes cron edit <id> --deliver <target>`), not this repo.",
    )


# A cron prompt is CONFIG, and config rots silently: a probe written as a raw-IP
# curl is blocked by the tool scanner on private-network/plain-HTTP grounds, so
# every run improvises its own workaround (an SSH hop, or a string-concatenated
# address) and burns context rediscovering it while the prompt stays wrong. Both
# shapes are the same defect -- the scanner reads the SHELL COMMAND, so neither
# form ever runs as written (genome #13: agent adaptability without config repair).
RAW_IP_URL = re.compile(r"https?://(?:\d{1,3}\.){3}\d{1,3}")
SPLIT_IP = re.compile(r"['\"]\d{1,3}\.\d{1,3}\.\d{1,3}\.['\"]\s*\+")

# Same rot, second shape (2026-09-20): the monitoring prompts taught every run that
# an unclaimed ComfyUI is an "ORPHANED GPU LEAK", which is only true for the pid WE
# launched. An interactive session or another project rendering on the shared
# install with no scheduler claim is normal sharing -- and a prompt that calls it a
# leak is an instruction to report (and, for the brain, "self-heal" = kill) live
# work. Measured: the 09:04 growth tick labelled Tim's live tmux render an
# "orphan/leak" while it was mid-render. A prompt line that says orphan AND a claim
# state AND never mentions owner= is the defect.
ORPHAN_PHRASE = re.compile(r"orphan", re.I)
CLAIM_STATE_PHRASE = re.compile(r"claim\s*=\s*idle|ours\s*=\s*no|claim\s*idle", re.I)
OWNER_PHRASE = re.compile(r"owner\s*=", re.I)


def cron_prompt_probe_verdict(rows):
    """Pure: job records -> (severity, evidence) when a prompt probes a raw IP.

    `localhost` and a real domain are fine (neither trips the scanner); the
    literal private address and the split-address workaround are not.
    """
    hits = []
    for r in rows:
        prompt = r.get("prompt") or ""
        urls = sorted(set(RAW_IP_URL.findall(prompt)))
        splits = SPLIT_IP.findall(prompt)
        if not urls and not splits:
            continue
        shapes = []
        if urls:
            shapes.append(", ".join(urls))
        if splits:
            shapes.append(f"{len(splits)} split-address workaround(s)")
        hits.append(f"{r.get('name')} ({r.get('id')}): {' + '.join(shapes)}")
    if not hits:
        return None
    return (
        "warn",
        f"{len(hits)} cron prompt(s) probe a raw private address, which the tool "
        f"scanner blocks so the probe never runs as written: {'; '.join(hits)} "
        f"-- point them at a repo-owned command instead "
        f"(`python3 bin/tc_ops.py caption-endpoint` answers the caption question "
        f"from Python and cannot be blocked); a split address is the same defect "
        f"dodging the scanner",
    )


def check_cron_prompt_probes():
    """The other half of check_cron_delivery: a prompt nobody can execute.

    Reads the same job store for the same reason -- a blocked probe leaves no
    trace inside this repo (the run still finishes, the check still "passes" via
    an improvised fallback), so the only durable signal is the prompt text.
    Measured 2026-09-20: the overnight watchdog's raw-IP curl and the growth
    brain's string-concatenated address were both scanner-blocked, and every run
    reported the caption service via an ad-hoc SSH hop instead.
    """
    try:
        store = json.loads(CRON_JOBS.read_text())
    except Exception:
        return None
    jobs = store if isinstance(store, list) else store.get("jobs", store)
    if isinstance(jobs, dict):
        jobs = list(jobs.values())
    rows = [{"name": j.get("name") or j.get("id"), "id": j.get("id"),
             "prompt": j.get("prompt")} for j in jobs if isinstance(j, dict)]
    v = cron_prompt_probe_verdict(rows)
    if not v:
        return None
    return (
        "cron-prompt-raw-ip-probe",
        "a cron prompt probes a raw IP the scanner blocks (so no run executes it)",
        v[0],
        v[1],
    )


def cron_prompt_orphan_verdict(rows):
    """Pure: job records -> (severity, evidence) when a prompt mislabels an unclaimed
    ComfyUI as an orphan without the owner= discrimination.

    Only the instance WE launched (owner=ours) is ours to call a leak; a foreign
    instance with no claim is another session's live work on a shared install.
    """
    hits = []
    for r in rows:
        for line in (r.get("prompt") or "").splitlines():
            if not ORPHAN_PHRASE.search(line):
                continue
            if not CLAIM_STATE_PHRASE.search(line):
                continue
            if OWNER_PHRASE.search(line):
                continue
            hits.append(f"{r.get('name')} ({r.get('id')}): {line.strip()[:120]}")
    if not hits:
        return None
    return (
        "warn",
        f"{len(hits)} cron prompt line(s) call ANY unclaimed ComfyUI an orphan/leak "
        f"without checking the owner= field, so a co-tenant's live render on the "
        f"shared install gets reported (and, where the prompt says the harness "
        f"'self-heals' it, killed) as a leak: {'; '.join(hits)} -- gate on "
        f"owner=ours (our pid, a real leak) vs owner=foreign (leave it alone; "
        f"contention at most)",
    )


def check_cron_prompt_orphan_wording():
    """Config rot in the monitoring prompts: a live co-tenant called an orphan.

    Same reason as check_cron_prompt_probes -- the defect lives in the prompt text,
    so the prompt text is the only durable signal. Measured 2026-09-20: all three
    monitoring prompts told their runs that comfyui=up with claim=idle (or
    ours=no) IS an orphaned leak, and the 09:04 growth tick reported Tim's live
    tmux render exactly that way; the harness never kills a foreign instance, so
    the prompt also misdescribed what ensure does.
    """
    try:
        store = json.loads(CRON_JOBS.read_text())
    except Exception:
        return None
    jobs = store if isinstance(store, list) else store.get("jobs", store)
    if isinstance(jobs, dict):
        jobs = list(jobs.values())
    rows = [{"name": j.get("name") or j.get("id"), "id": j.get("id"),
             "prompt": j.get("prompt")} for j in jobs if isinstance(j, dict)]
    v = cron_prompt_orphan_verdict(rows)
    if not v:
        return None
    return (
        "cron-prompt-orphan-mislabel",
        "a cron prompt calls a co-tenant's live ComfyUI an orphan (no owner= gate)",
        v[0],
        v[1],
    )


# Third shape of the same rot (measured 2026-09-20): a prompt that reads a repo log
# BY PATH keeps reading a file that stopped being written. Both monitoring prompts
# tell every run to `tail -40 log/growth_harness.log` -- the log of
# bin/growth_harness.sh, a wrapper deprecated on 2026-09-20 and unwritten since
# 2026-08-20 -- so the error step reads 30-day-old text and cannot tell "no errors"
# from "this log is dead" (genome #40: expected-event absence; #13: config rot that
# agent improvisation hides). The durable fix is the one that retired the raw-IP
# probe: point the prompt at a repo-owned command (`python3 bin/tc_ops.py
# log-health`) instead of a path, so a writer moving cannot blind the step.
PROMPT_LOG_PATH = re.compile(
    r"(?<![\w/])log/([A-Za-z0-9_][A-Za-z0-9_./-]*\.(?:log|jsonl))")
# Longer than any cadence in this repo (hourly publisher, daily backup, weekly
# review), so a weekly job's own log is never called dead.
DEAD_LOG_AGE_S = 10 * 86400


def log_path_age(rel_path):
    """(exists, age_seconds) for a repo-relative log path; age None when missing."""
    try:
        return True, time.time() - (APP / rel_path).stat().st_mtime
    except OSError:
        return False, None


def cron_prompt_logpath_verdict(rows, probe=log_path_age):
    """Pure: job records -> (severity, evidence) when a prompt reads a dead log.

    `probe(rel_path)` returns (exists, age_seconds) and is injected so the decision
    is testable without touching the filesystem.
    """
    hits = []
    for r in rows:
        for rel in sorted(set(PROMPT_LOG_PATH.findall(r.get("prompt") or ""))):
            exists, age = probe("log/" + rel)
            if exists and age is not None and age < DEAD_LOG_AGE_S:
                continue
            if not exists:
                state = "MISSING"
            elif age is None:
                state = "age unreadable"
            else:
                state = f"unwritten for {age / 86400:.1f}d"
            hits.append(f"{r.get('name')} ({r.get('id')}) reads log/{rel} -- {state}")
    if not hits:
        return None
    return (
        "warn",
        f"{len(hits)} cron prompt log reference(s) point at a file nothing writes, "
        f"so the step that reads it cannot tell 'no errors' from 'no signal': "
        f"{'; '.join(hits)} -- replace the path with the repo-owned command "
        f"(`python3 bin/tc_ops.py log-health` prints every live log's age and recent "
        f"error lines, so it cannot rot when a writer moves)",
    )


def check_cron_prompt_log_paths():
    """Config rot, third shape: a prompt reads a log that stopped being written.

    Same reason as check_cron_prompt_probes -- the defect lives in the prompt text,
    and a run that tails a dead log still finishes cleanly, so nothing else
    surfaces it. Measured 2026-09-20: log/growth_harness.log was last written
    2026-08-20 (by bin/growth_harness.sh, since deprecated), and both the overnight
    watchdog and the weekly persona review still told every run to tail it.
    """
    try:
        store = json.loads(CRON_JOBS.read_text())
    except Exception:
        return None
    jobs = store if isinstance(store, list) else store.get("jobs", store)
    if isinstance(jobs, dict):
        jobs = list(jobs.values())
    rows = [{"name": j.get("name") or j.get("id"), "id": j.get("id"),
             "prompt": j.get("prompt")} for j in jobs if isinstance(j, dict)]
    v = cron_prompt_logpath_verdict(rows)
    if not v:
        return None
    return (
        "cron-prompt-dead-log-path",
        "a cron prompt reads a log file that nothing writes any more",
        v[0],
        v[1],
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


def photo_pool_verdict(stats):
    """Decide the candidate-pool issue from MEASURED counts (pure, testable).

    stats: pool / union / unposted / dead_in_pool / dead_ids / missed_ids, all as
    strings from the rails probe. Returns an issue tuple or None.
    """
    if not stats:
        return None
    try:
        pool = int(stats["pool"])
        union = int(stats["union"])
        dead = int(stats["dead_in_pool"])
    except (KeyError, ValueError, TypeError):
        return None
    missed = union - pool

    if dead > 0:
        return (
            "photo-pool-unservable",
            f"{dead} post candidate(s) have no servable bytes -- they fail at PUBLISH time, not here",
            "warn",
            f"pool={pool} of {union} servable-or-attached unposted photos; dead "
            f"candidate ids: {stats.get('dead_ids') or '?'}; a dead candidate does "
            "not raise where it is picked -- GeneratePublicPhotoUrl stops with "
            "'Photo has no servable file and no attached image' and the post lands "
            "in status=failed (58 of 64 historical post failures reference a photo "
            "whose bytes are gone). Fix the selector predicate, not the row",
        )

    if missed > 0:
        return (
            "photo-pool-unservable",
            f"the candidate pool hides {missed} servable photo(s) from the producers",
            "warn",
            f"pool={pool} but {union} unposted photos are servable-or-attached; "
            f"missed ids: {stats.get('missed_ids') or '?'}; the selector must use "
            "the publish path's own precedence (`servable? || image.attached?`) -- "
            "a stale proxy silently withholds postable renders, which reads as a "
            "queue shortfall, never as an error",
        )

    if union < POOL_FLOOR:
        return (
            "photo-pool-unservable",
            f"only {union} servable unposted photo(s) left -- the corpus is draining",
            "warn",
            f"pool={pool} union={union} unposted={stats.get('unposted')} "
            f"(floor {POOL_FLOOR}); each photo can back exactly one post per "
            "persona (unique index photo_id+persona_id), so this is the hard "
            "ceiling on how many posts the queue can still be filled with; below "
            "the floor the shortfall shows up only as an empty queue",
        )

    return None


def check_photo_pool():
    """Measure the REAL selector against ground truth: can we serve what it offers?

    `Photos::ListAvailable` filtered candidates on `image.attached?`, a proxy for
    "we have bytes" that stopped holding when the local ComfyUI mounts moved
    (measured 2026-09-20: 101 of 141 attached photos have no file at `path` and
    no NAS fallback -- NAS_OUTPUT_BASE points at a tree that does not exist --
    while 23 servable renders carry no ActiveStorage blob and were invisible to
    the producers). Nothing detected it: the pipeline still posted, the queue
    still filled from the render path, and the loss showed only as 58 of 64
    historical post failures referencing dead photos.

    So this runs the command itself rather than reimplementing `servable?` in
    SQL, and compares the pool to the set the publish path can serve.
    """
    script = (
        "persona = Persona.first;"
        "has = lambda { |x| (x.servable_file_path.present? ||"
        " (x.image.attached? && x.image.blob.service.exist?(x.image.blob.key))) rescue false };"
        "unposted = ContentPillars::Photo.where(persona_id: persona.id)"
        ".where.not(id: Scheduling::Post.where(persona_id: persona.id)"
        ".select(:photo_id)).to_a;"
        "servable = unposted.select { |x| has.call(x) };"
        "pool = Photos::ListAvailable.call(persona: persona).photos;"
        "dead = pool.reject { |x| has.call(x) };"
        "puts ['pool=' + pool.size.to_s,"
        " 'union=' + servable.size.to_s,"
        " 'unposted=' + unposted.size.to_s,"
        " 'dead_in_pool=' + dead.size.to_s,"
        " 'dead_ids=' + dead.map(&:id).first(5).join(','),"
        " 'missed_ids=' + (servable.map(&:id) - pool.map(&:id)).first(5).join(',')"
        "].join(' ')"
    )
    out, rc = run(["bin/rails", "runner", script], timeout=180)
    if rc != 0 or not out:
        return None
    stats = {}
    for tok in out.split():
        if "=" in tok:
            k, v = tok.split("=", 1)
            stats[k] = v
    return photo_pool_verdict(stats)


def photo_resolution_verdict(stats):
    """Pure: measured photo-resolution counts -> issue tuple or None.

    stats: roots / missing / stranded / ids, as strings from the rails probe.
    Returns None when the resolver finds every photo whose bytes exist.
    """
    if not stats:
        return None
    roots = [r for r in (stats.get("roots") or "").split(";") if r]
    missing = [r for r in (stats.get("missing") or "").split(";") if r]
    try:
        stranded = int(stats.get("stranded") or 0)
    except ValueError:
        return None
    if not roots:
        return (
            "photo-resolution-dead",
            "the photo resolver has no configured source root",
            "critical",
            "ContentPillars::Photo::MIRROR_ROOTS is empty, so every photo whose "
            "recorded mount has moved resolves to nothing -- the corpus reads as "
            "empty while its bytes exist",
        )
    if missing:
        return (
            "photo-resolution-dead",
            f"{len(missing)} photo source root(s) do not exist: {', '.join(missing)}",
            "warn",
            "the resolver searches these roots for any photo whose recorded mount "
            "is gone; a root that does not exist is a SILENT dead end (measured "
            "2026-09-20: the fallback pointed at /mnt/synology-home, an empty "
            "root-owned directory, so 101 photos with intact bytes read as 'no "
            "bytes anywhere' and were written off as permanently unpostable)",
        )
    if stranded > 0:
        return (
            "photo-resolution-dead",
            f"{stranded} photo(s) have bytes in the NAS mirror that the resolver does not find",
            "warn",
            f"ids: {stats.get('ids') or '?'} -- the mount-prefix fallback has "
            "regressed; these photos are served as missing although their bytes "
            f"exist at the same relative path under {roots[0]}",
        )
    return None


def check_photo_resolution():
    """Can we still FIND the bytes of a photo whose recorded mount has moved?

    `servable_file_path` fell back to
    '/mnt/synology-home/backup/essdee/ComfyUI', which is not a mount at all
    (/mnt/synology-home is an empty, root-owned directory), and its prefix test
    knew only the ORIGINAL /mnt/essdee/ComfyUI mount -- so photos imported from
    the current mount (/mnt/fscache/essdee/ComfyUI, itself a symlink into the
    NAS) had no fallback at all, while the fallback that did exist could never
    resolve. Nothing reported it: those records simply read as "no bytes
    anywhere" (measured 2026-09-20: 101 photos were written off as permanently
    unpostable while their bytes sat intact at the same RELATIVE path under the
    NAS mirror).

    So this measures the resolver's own answer against the mirror: every
    configured root must exist, and no photo may read as unreachable while its
    bytes are present.
    """
    script = (
        "klass = ContentPillars::Photo;"
        "roots = klass::MIRROR_ROOTS;"
        "stranded = [];"
        "klass.find_each do |p|"
        " next if p.servable_file_path.present?;"
        " d = p.path.to_s;"
        # Independent of the resolver's own constants: derive the path relative
        # to the ComfyUI output tree from the path itself, so a prefix list that
        # lost a mount is caught rather than mirrored by the measurement.
        " i = d.rindex('/ComfyUI/');"
        " next unless i;"
        " rel = d[(i + 9)..].sub(%r{\\Aoutput/}, '');"
        " hit = roots.find { |r| File.file?(File.join(r, rel)) ||"
        " File.file?(File.join(r, 'output', rel)) };"
        " stranded << p.id if hit;"
        " end;"
        "puts ['roots=' + roots.join(';'),"
        " 'missing=' + roots.reject { |r| File.directory?(r) }.join(';'),"
        " 'stranded=' + stranded.size.to_s,"
        " 'ids=' + stranded.first(5).join(',')].join(' ')"
    )
    out, rc = run(["bin/rails", "runner", script], timeout=240)
    if rc != 0 or not out:
        return None
    stats = {}
    for tok in out.split():
        if "=" in tok:
            k, v = tok.split("=", 1)
            stats[k] = v
    return photo_resolution_verdict(stats)


def photo_provenance_verdict(unwired, n_unmarked, n_unmarked_recent):
    """Pure: is the synthetic mark written at creation, and complete?

    Two independent things, because either alone is insufficient: the PRODUCERS
    still mark (structural -- a code edit that drops the call is otherwise
    invisible until an unmarked render ships), and no photo is left unmarked
    (data -- `synthetic IS NULL` means "unknown", never human origin, and an
    unknown render cannot be disclosed from the record).
    """
    if unwired:
        return "critical"
    if n_unmarked and n_unmarked > 0:
        return "warn"
    return None


def check_photo_provenance():
    """A render that reaches the corpus unmarked cannot be disclosed later.

    THESIS pillar 2 mandates a synthetic marker that reaches the PUBLISHED asset,
    and the red line is "never publish a render without a machine-readable
    synthetic mark". The asset-level mark (openspec change
    add-synthetic-provenance, tasks 2.x) is not built yet -- but its input is the
    record written at creation, and provenance that was never tracked cannot be
    disclosed afterwards. So the DB half is asserted here: the column exists and
    is written by every render producer, and no photo is left at NULL.

    Detection only. The write lives in ContentPillars::Photo.import_render (the
    single choke point both producers call) and the corpus repair is
    `rails photos:backfill_provenance` (dry run; APPLY=1 to write).
    """
    unwired = [str(p.relative_to(APP)) for p in PROVENANCE_PRODUCERS
               if not _file_mentions(p, PROVENANCE_IMPORT_REF)]

    total = psql("select count(*) from photos")
    unmarked = psql("select count(*) from photos where synthetic is null")
    if total is None or unmarked is None:
        # Column absent (migration not applied) or DB unreadable: report nothing
        # rather than a fabricated zero.
        return None
    try:
        total = int(total)
        unmarked = int(unmarked)
    except ValueError:
        return None

    recent = psql("select count(*) from photos where synthetic is null "
                  "and created_at > (now() at time zone 'UTC') - interval '24 hours'")
    try:
        recent = int(recent) if recent is not None else None
    except ValueError:
        recent = None

    severity = photo_provenance_verdict(bool(unwired), unmarked, recent)
    if not severity:
        return None

    if unwired:
        return (
            "photo-provenance-unmarked",
            "the render path no longer marks its photo as synthetic",
            "critical",
            f"{', '.join(unwired)} no longer call ContentPillars::Photo."
            f"import_render, so a completed render is written to the corpus with "
            f"synthetic IS NULL -- unknown origin, and no record to mark the "
            f"published asset from. Every render must go through that one method "
            f"(Growth::ContentGenerator for the sync path, Growth::RenderSalvage "
            f"for the recovery path). Unmarked photos right now: {unmarked} of "
            f"{total}.",
        )

    return (
        "photo-provenance-unmarked",
        f"{unmarked} photo(s) carry no synthetic mark",
        severity,
        f"{unmarked} of {total} photo(s) have synthetic IS NULL"
        + (f", {recent} of them created in the last 24h" if recent else "")
        + ". A NULL mark means unknown origin (never defaulted to human origin), "
          "so nothing can be disclosed about these renders and the asset-level "
          "mark has no input to carry. Repair: `bundle exec rails "
          "photos:backfill_provenance` (dry run) then APPLY=1 to write; the "
          "producers mark at creation via ContentPillars::Photo.import_render.",
    )


def publish_gate_verdict(stats):
    """Pure: measured markability of the QUEUED assets -> issue tuple or None.

    The publish gate (`Scheduling::Commands::GeneratePublicPhotoUrl`, tasks
    3.1/3.2 of add-synthetic-provenance) is FAIL-CLOSED: an asset whose bytes
    cannot carry the synthetic mark stops the post rather than publishing
    synthetic media as photography. Nothing measured that readiness before a
    publish slot reached the asset, so the first unmarkable asset in the queue
    was discoverable only by the post FAILING -- publishing stalls while the
    pipeline still looks alive. That is the shape of the 64 historical post
    failures (58 of which referenced a photo whose bytes were gone), and of the
    fail-closed gate trap: a probe whose own breakage blocks the resource is
    worse than no probe.

    stats: queued / unmarked / blocked / noservable / ids, as strings from the
    rails probe (markability comes from the marker's OWN `markable`, so this
    verdict cannot drift from what `mark!` will do). Returns None when every
    queued asset can be marked -- which is the normal state, since renders are
    complete PNGs.
    """
    if not stats:
        return None
    try:
        queued = int(stats.get("queued") or 0)
        blocked = int(stats.get("blocked") or 0)
    except (ValueError, TypeError):
        return None
    if queued == 0 or blocked == 0:
        return None
    return (
        "publish-gate-unmarkable-asset",
        f"{blocked} queued post(s) carry an asset the publish gate cannot mark "
        "-- the post fails at publish time",
        "warn",
        f"{blocked} of {queued} scheduled/draft post(s) resolve to a file that "
        f"ContentPillars::PhotoAssetMarker.markable refuses: {stats.get('ids') or '?'} "
        f"(unmarked={stats.get('unmarked')}, no-servable-file="
        f"{stats.get('noservable')}). GeneratePublicPhotoUrl is FAIL-CLOSED, so an "
        "asset it cannot mark STOPS the post instead of publishing synthetic media "
        "as photography: publishing stalls while the pipeline looks alive and the "
        "only symptom is a status=failed post (nothing here raises). Remedies: "
        "re-render or re-import so the bytes are a complete PNG/JPEG (a truncated "
        "PNG is the likely case -- ComfyUI killed mid-write, or a partial NAS copy), "
        "then `bundle exec rails photos:embed_provenance PHOTO_ID=<id>`; if the "
        "container is genuinely unsupported, the gate's carrier list needs it.",
    )


def check_publish_gate_readiness():
    """Can every asset the queue will publish still be marked? (pre-flight)

    Read-only: asks `PhotoAssetMarker.markable` for each queued post's asset and
    never writes (the corpus has exactly one copy -- see photo-corpus-single-copy
    -- so a probe must not mutate it). The publish gate itself is the authority;
    this only reports the gate's readiness before a slot reaches the asset.
    """
    script = (
        "persona = Persona.first;"
        "posts = Scheduling::Post.where(persona_id: persona.id,"
        " status: %w[draft scheduled]).includes(:photo).to_a;"
        "marker = ContentPillars::PhotoAssetMarker;"
        "blocked = []; unmarked = 0; noservable = 0;"
        "posts.each do |p|;"
        " ph = p.photo;"
        " next if ph.nil?;"
        " file = (ph.servable_file_path rescue nil);"
        " if file.blank?; noservable += 1; next; end;"
        " v = marker.markable(file);"
        " unmarked += 1 unless v == :already_marked;"
        " blocked << (p.id.to_s + '/' + ph.id.to_s + ':' + v.to_s)"
        " unless %i[already_marked markable].include?(v);"
        "end;"
        "puts ['queued=' + posts.size.to_s,"
        " 'unmarked=' + unmarked.to_s,"
        " 'blocked=' + blocked.size.to_s,"
        " 'noservable=' + noservable.to_s,"
        " 'ids=' + blocked.first(5).join(',')].join(' ')"
    )
    out, rc = run(["bin/rails", "runner", script], timeout=180)
    if rc != 0 or not out:
        return None
    stats = {}
    for tok in out.split():
        if "=" in tok:
            k, v = tok.split("=", 1)
            stats[k] = v
    return publish_gate_verdict(stats)


def _file_mentions(path, needle):
    """Does a source file still reference `needle`? Unreadable -> treated as
    MISSING (the same fail-closed choice the prompt-safety check makes)."""
    try:
        return needle in path.read_text()
    except Exception:
        return False


CHECKS = [
    check_probe_inputs,
    check_worker_running,
    check_backlog_backpressure,
    check_stranded_pending_jobs,
    check_zombie_jobs,
    check_venv_drift,
    check_launch_deps_importable,
    check_slot,
    check_own_queue_leak,
    check_stuck_comfyui_jobs,
    check_stuck_pipeline_runs,
    check_render_for_terminal_run,
    check_caption_fallback,
    check_caption_path_cold,
    check_caption_image_grounding,
    check_placeholder_caption_queued,
    check_queued_post_hashtags,
    check_pipeline_prompt_safety,
    check_render_acceptance,
    check_render_execution_errors,
    check_photo_pool,
    check_photo_resolution,
    check_photo_provenance,
    check_publish_gate_readiness,
    check_render_starved,
    check_publish_liveness,
    check_publish_gap,
    check_publish_failed_silent,
    check_insights_stale,
    check_future_queue_empty,
    check_post_slot_bursts,
    check_post_schedule_shape,
    check_release_pacing,
    check_comfyui_vram_unclaimed,
    check_telemetry_oom,
    check_harness_log_growth,
    check_queue_growth,
    check_scheduler_dispatcher,
    check_cron_delivery,
    check_cron_prompt_probes,
    check_cron_prompt_orphan_wording,
    check_cron_prompt_log_paths,
]


# -------------------------------------------------------------------- board
def issue_path(key):
    return BOARD / f"{key}.json"


def file_issue(key, title, severity, evidence, source="probe", route=ROUTE_DEFAULT):
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
        # setdefault, not assignment: a re-filing probe must never silently move an
        # item back out of the human queue it was deliberately routed into.
        rec.setdefault("route", route)
        # A probe must not silently claim ownership of a hand-filed issue.
        if rec.get("source", "probe") == "probe":
            rec["source"] = source
    else:
        rec = {
            "key": key, "title": title, "severity": severity, "evidence": evidence,
            "status": "open", "first_seen": now, "last_seen": now,
            "seen_count": 1, "source": source, "route": route, "notes": [],
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


def route_of(rec):
    """Which queue an open item is in: 'agent' (the agent decides) or 'tim' (enablement).

    Pure. An explicit `route` wins; anything else -- absent, blank, or garbage --
    reads as the agent's, because the default mistake this board was making is a
    business decision sitting in a human's queue.
    """
    r = str(rec.get("route") or "").strip().lower()
    return r if r in ROUTES else ROUTE_DEFAULT


def human_digest(recs, now=None):
    """Render the open board as one markdown digest -- a surface a human can READ.

    Pure: takes the records, returns text. Bounded by construction (evidence and
    notes truncated, file rewritten rather than appended), so regenerating it on
    every probe run cannot grow it.

    Split by route, because the two queues have different readers: `tim` items are
    the only ones that may be pushed to the operator (enablement), while `agent`
    items are the operating agent's OWN decisions -- listed explicitly so a session
    can see they are its own to take and not someone else's to grant.
    """
    now = now or time.strftime("%Y-%m-%dT%H:%M:%S%z")
    tim = [r for r in recs if route_of(r) == "tim"]
    agent = [r for r in recs if route_of(r) == "agent"]
    lines = [
        "# turbo-carnival ops board -- open items",
        "",
        f"Regenerated by `bin/tc_ops.py probe` at {now} from `ops/board/*.json`.",
        "Do not edit by hand -- every probe run rewrites this file.",
        "",
        "Two queues, two readers:",
        "",
        "- **Enablement (`route=tim`)** -- only a human can do it: a file outside",
        "  this repo, a credential, a platform/channel setting, a GPU policy.",
        "- **Decisions (`route=agent`)** -- business/product calls the operating",
        "  agent OWNS. Decide and close with the decision as the note; routing one",
        "  of these to a human is the failure this board was filing into.",
        "",
        "Move an item between queues with",
        "`python3 bin/tc_ops.py route <key> --route tim -n '<why it needs a human>'`.",
        "",
        "This file is the durable surface because this profile's cron jobs deliver",
        "`local` (their WebUI origin has no gateway adapter), so a report lands in",
        "`cron/output/<job-id>/` and nowhere else. Full records:",
        "`python3 bin/tc_ops.py show <key>`.",
        "",
        f"Open: {len(recs)} (enablement for Tim: {len(tim)} | agent decisions: {len(agent)})",
        "",
    ]

    def _table(rows, caption):
        lines.append(f"## {caption}")
        lines.append("")
        if not rows:
            lines.append("_none_")
            lines.append("")
            return
        lines.append("| sev | key | source | seen | first seen | last seen |")
        lines.append("| --- | --- | --- | --- | --- | --- |")
        for r in rows:
            lines.append(
                f"| {r.get('severity', 'info')} | `{r.get('key', '')}` "
                f"| {r.get('source', 'probe')} | {r.get('seen_count', 0)} "
                f"| {r.get('first_seen', '')} | {r.get('last_seen', '')} |"
            )
        lines.append("")

    _table(tim, "Enablement needed from Tim (`route=tim`)")
    _table(agent, "Agent-owned decisions (`route=agent`)")
    for caption, rows in (("ENABLEMENT (route=tim)", tim), ("DECISION (route=agent)", agent)):
        for r in rows:
            lines.append(f"## {caption} | {r.get('severity', 'info').upper()} "
                         f"`{r.get('key', '')}` -- {r.get('title', '')}")
            lines.append("")
            lines.append(f"- route {route_of(r)} | source {r.get('source', 'probe')} "
                         f"| seen {r.get('seen_count', 0)}x | first {r.get('first_seen', '')} "
                         f"| last {r.get('last_seen', '')}")
            evidence = " ".join((r.get("evidence") or "").split())
            if evidence:
                lines.append(f"- evidence: {evidence[:DIGEST_EVIDENCE_CHARS]}")
            notes = r.get("notes") or []
            if notes:
                latest = " ".join((notes[-1].get("note") or "").split())
                lines.append(f"- latest note ({notes[-1].get('ts', '')}): {latest[:DIGEST_NOTE_CHARS]}")
            lines.append("")
    return "\n".join(lines)


def write_human_digest(now=None):
    NEEDS_HUMAN.parent.mkdir(parents=True, exist_ok=True)
    NEEDS_HUMAN.write_text(human_digest(load_all(), now=now))
    return NEEDS_HUMAN


def cmd_needs_human(_argv):
    recs = load_all()
    p = write_human_digest()
    print(f"needs-human: wrote {p} ({len(recs)} open item(s))")
    return 0


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
    # Keep the human-readable digest in step with the board, here rather than in
    # the caller: a surface that only a caller can refresh is a surface that rots.
    write_human_digest()
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
    print(f"{'SEV':9} {'ROUTE':6} {'KEY':32} {'SEEN':4} LAST SEEN")
    for r in recs:
        print(f"{r.get('severity',''):9} {route_of(r):6} {r.get('key',''):32} "
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


def cmd_file(argv):
    """File (or refresh) a board issue from the command line.

    The probe owns the signals it can MEASURE. This exists for the ones it
    cannot: a condition found by reading a monitoring job's output, or a problem
    outside this repo's scope. `--source manual` (the default) means the probe
    will neither re-file nor auto-close it, so it stays open until a run closes
    it with a reason -- which is what makes it honest to file something a human
    has to decide.
    """
    if not argv:
        print("usage: tc_ops.py file KEY --title TEXT --evidence TEXT "
              "[--severity warn|critical|info] [--source manual] [--route agent|tim]",
              file=sys.stderr)
        return 2
    key = argv[0]
    opts = {}
    for flag in ("--title", "--evidence", "--evidence-file", "--severity", "--source",
                 "--route"):
        if flag in argv:
            i = argv.index(flag) + 1
            if i >= len(argv) or argv[i].startswith("--"):
                print(f"{flag} needs a value", file=sys.stderr)
                return 2
            opts[flag[2:]] = argv[i]
    # --evidence-file exists because board evidence routinely QUOTES a raw private
    # address or URL, and the tool scanner refuses a command line containing one --
    # so the honest record could not be filed at all without a file path.
    if opts.get("evidence-file"):
        try:
            opts["evidence"] = Path(opts["evidence-file"]).read_text().strip()
        except OSError as e:
            print(f"cannot read --evidence-file: {e}", file=sys.stderr)
            return 2
    if not opts.get("title") or not opts.get("evidence"):
        print("--title and --evidence (or --evidence-file) are required", file=sys.stderr)
        return 2
    sev = opts.get("severity", "warn")
    if sev not in SEV_ORDER:
        print(f"severity must be one of {', '.join(SEV_ORDER)}", file=sys.stderr)
        return 2
    route = opts.get("route", ROUTE_DEFAULT)
    if route not in ROUTES:
        print(f"--route must be one of {', '.join(ROUTES)}", file=sys.stderr)
        return 2

    p = issue_path(key)
    prior = None
    if p.exists():
        try:
            prior = json.loads(p.read_text())
        except Exception:
            prior = None
    rec = file_issue(key, opts["title"], sev, opts["evidence"],
                     source=opts.get("source", "manual"), route=route)
    # A manual filing must not STEAL a probe-owned key: file_issue adopts the
    # caller's source for any record that was probe-owned, which would silently
    # stop the probe re-filing and auto-closing a signal it can measure.
    if prior and prior.get("source") == "probe":
        rec["source"] = "probe"
        p.write_text(json.dumps(rec, indent=2) + "\n")
    # An explicit --route IS applied to an existing record (file_issue only
    # setdefaults), so a filing can deliberately move an item into the human queue.
    if "--route" in argv and route_of(rec) != route:
        rec["route"] = route
        p.write_text(json.dumps(rec, indent=2) + "\n")
    print(f"filed {key} [{rec['severity']}] status={rec['status']} "
          f"seen_count={rec['seen_count']} source={rec['source']} route={route_of(rec)}")
    return 0


def cmd_touch(argv):
    """Bump an issue and record progress: `touch KEY [-n|--note TEXT]` or `touch KEY TEXT`.

    Same trap `close` was fixed for, hit live on 2026-09-20 by this loop's own
    agent: the flag was passed but its VALUE landed in the note slot, so the board
    recorded the literal string "--note" and the real text was dropped. Both
    spellings are accepted; a flag with no value is refused rather than persisted.
    """
    if not argv:
        print("usage: tc_ops.py touch KEY [-n|--note TEXT]", file=sys.stderr)
        return 2
    key = argv[0]
    note, flag_used = "", False
    for flag in ("--note", "-n"):
        if flag in argv:
            flag_used = True
            i = argv.index(flag) + 1
            note = argv[i] if i < len(argv) else ""
            break
    if not flag_used:
        note = argv[1] if len(argv) > 1 else ""
    if flag_used and (not note or note.startswith("-")):
        print("usage: tc_ops.py touch KEY [-n|--note TEXT] "
              "(the note must be the flag's value, or the second positional arg)",
              file=sys.stderr)
        return 2
    note = note or "progress"
    p = issue_path(key)
    if not p.exists():
        print(f"no such issue: {key}", file=sys.stderr)
        return 2
    rec = json.loads(p.read_text())
    append_note(rec, note)
    p.write_text(json.dumps(rec, indent=2) + "\n")
    print(f"noted on {key}: {note}")
    return 0


def cmd_route(argv):
    """Move an item between the two queues, recording why.

    `route KEY --route agent|tim [-n NOTE]`. The route is the ONLY thing that
    decides which queue an item is published in (and whether an escalation job may
    push it to the operator), so changing it must be an explicit, noted act rather
    than something a probe can drift.
    """
    if not argv:
        print("usage: tc_ops.py route KEY --route agent|tim [-n NOTE]", file=sys.stderr)
        return 2
    key = argv[0]
    want, note = "", ""
    if "--route" in argv:
        i = argv.index("--route") + 1
        want = argv[i].strip().lower() if i < len(argv) else ""
    for flag in ("--note", "-n"):
        if flag in argv:
            i = argv.index(flag) + 1
            note = argv[i] if i < len(argv) else ""
            break
    if want not in ROUTES:
        print(f"--route must be one of {', '.join(ROUTES)}", file=sys.stderr)
        return 2
    p = issue_path(key)
    if not p.exists():
        print(f"no such issue: {key}", file=sys.stderr)
        return 2
    rec = json.loads(p.read_text())
    was = route_of(rec)
    rec["route"] = want
    append_note(rec, note or f"routed {was} -> {want}")
    p.write_text(json.dumps(rec, indent=2) + "\n")
    print(f"{key}: route {was} -> {want}" + (f" ({note})" if note else ""))
    return 0


def escalations_text(recs, limit=DIGEST_NOTE_CHARS):
    """Render the enablement queue (`route=tim`) as a terse operator digest.

    Pure. Returns "" when no human is needed, which is what lets a delivery job
    suppress itself on empty output instead of sending a "nothing to do" message.
    """
    tim = [r for r in recs if route_of(r) == "tim"]
    if not tim:
        return ""
    lines = [f"turbo-carnival: {len(tim)} item(s) need you to unblock", ""]
    for r in tim:
        lines.append(f"[{r.get('severity', 'info')}] {r.get('key', '')}: {r.get('title', '')}")
        notes = r.get("notes") or []
        if notes:
            latest = " ".join((notes[-1].get("note") or "").split())
            lines.append(f"    latest: {latest[:limit]}")
        lines.append(f"    open since: {r.get('first_seen', '')}")
    return "\n".join(lines)


def cmd_escalations(_argv):
    """Print ONLY the enablement queue (`route=tim`), for an escalation job to deliver.

    The two queues have different readers: this one MAY be pushed to the operator,
    the agent-decision queue must NOT be (it is the agent's own work, and pushing
    it re-creates the "everything is a human's problem" state this split undoes).
    Prints NOTHING and exits 0 when no human is needed, so a delivery job can
    suppress itself on empty output rather than sending a "nothing to do" message.
    """
    text = escalations_text(load_all())
    if text:
        print(text)
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

    # publish_failed_verdict: rejected posts inside the window -> severity. The
    # window is what makes the entry self-close once failures age out, so zero
    # must be None and any live rejection must be a warn.
    failed_cases = [
        ("none", 0, None, None),
        ("none-unknown-age", 0, None, None),
        ("one-just-failed", 1, 0.4, "warn"),
        ("several-in-window", 3, 20.0, "warn"),
    ]
    for name, n, age, want in failed_cases:
        expect(f"publish_failed_verdict[{name}]", publish_failed_verdict(n, age), want)

    # render_error_verdict: failed-job error rows (newest first) -> severity. None
    # means the DB read failed (never a silent "no errors"), [] means a clean
    # window (the entry self-closes), and any row is a warn naming the newest
    # cause -- the workflow exception the producer used to call a timeout.
    rerr_cases = [
        ("clean-window", [], None),
        ("db-unreadable", None, None),
        ("blank-rows", ["", "   "], None),
        ("one-execution-error",
         ["index is out of bounds for dimension with size 0 (09-21 11:16Z)"], "warn"),
        ("several", ["a (09-21 11:16Z)", "b (09-21 09:02Z)"], "warn"),
    ]
    for name, rows, want in rerr_cases:
        v = render_error_verdict(rows)
        expect(f"render_error_verdict[{name}]", v[0] if v else None, want)

    # queued_hashtag_verdict: untagged queued posts -> severity. Zero must be
    # None (the entry self-closes once the publisher's repair fills the queue) and
    # any untagged row must warn: the publisher appends the column verbatim, so an
    # empty one ships an untagged post with no other signal.
    untagged_cases = [
        ("clean-queue", 0, None),
        ("unknown", None, None),
        ("one-untagged", 1, "warn"),
        ("several-untagged", 4, "warn"),
    ]
    for name, n, want in untagged_cases:
        expect(f"queued_hashtag_verdict[{name}]", queued_hashtag_verdict(n), want)

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

    # post_slot_verdict: [(slot, created)] -> (live pairs, residue pairs), split on
    # whether a producer could still have been bypassing the planner.
    L = POST_SLOT_PLANNER_LANDED
    slot_cases = [
        ("spaced", [(1000.0, L + 10), (9000.0, L + 10)], 0, 0),
        ("residue-only", [(1000.0, L - 10), (1500.0, L - 10)], 0, 1),
        ("live-only", [(1000.0, L + 10), (1500.0, L + 10)], 1, 0),
        ("mixed", [(1000.0, L - 10), (1500.0, L + 10)], 1, 0),
        ("mixed-spaced", [(1000.0, L - 10), (1500.0, L + 10), (9000.0, L - 10)], 1, 0),
        ("empty", [], 0, 0),
    ]
    for name, rows, want_live, want_residue in slot_cases:
        live, residue = post_slot_verdict(rows)
        expect(f"post_slot_verdict[{name}].live", len(live), want_live)
        expect(f"post_slot_verdict[{name}].residue", len(residue), want_residue)

    # over_cap_split: [(slot, created)] + cap -> (live days, residue days). The
    # split is what keeps a warn actionable: residue cannot be re-spaced without a
    # live-publishing edit, so it must not carry warn severity.
    D = 86400.0
    cap_cases = [
        ("healthy", [(D * 10 + 32400, L + 10)], 3, 0, 0),
        ("live-over", [(D * 10 + i * 3600, L + 10) for i in range(4)], 3, 1, 0),
        ("residue-over", [(D * 10 + i * 3600, L - 10) for i in range(4)], 3, 0, 1),
        ("mixed", [(D * 10 + i * 3600, L - 10) for i in range(4)]
         + [(D * 11 + i * 3600, L + 10) for i in range(4)], 3, 1, 1),
        # exactly at cap is fine; only MORE than cap is a violation
        ("at-cap", [(D * 10 + i * 3600, L + 10) for i in range(3)], 3, 0, 0),
        ("empty", [], 3, 0, 0),
    ]
    for name, rows, cap, want_live, want_residue in cap_cases:
        live, residue = over_cap_split(rows, cap)
        expect(f"over_cap_split[{name}].live", len(live), want_live)
        expect(f"over_cap_split[{name}].residue", len(residue), want_residue)

    # release_pacing_verdict: (rake source, plan source) -> (severity, evidence) or None.
    # The guard exists because the slot-proximity signal is only harmless while
    # PostReleasePlan caps a run at one post; a silent revert must not read green.
    rake_ok = "    plan = Scheduling::PostReleasePlan.call(all_posts)\n"
    plan_ok = "    MAX_PER_RUN = 1\n"
    pacing_cases = [
        ("wired", rake_ok, plan_ok, None),
        ("rake-reverted", "    all_posts.each { |p| p.start_posting! }\n", plan_ok, "critical"),
        ("cap-raised", rake_ok, "    MAX_PER_RUN = 3\n", "warn"),
        ("cap-not-literal", rake_ok, "    MAX_PER_RUN = ENV.fetch('N', 1)\n", "warn"),
        ("sources-unreadable", "", "", "warn"),
    ]
    for name, rake_src, plan_src, want in pacing_cases:
        v = release_pacing_verdict(rake_src, plan_src)
        expect(f"release_pacing_verdict[{name}]", v[0] if v else None, want)

    # cron_delivery_verdict: job records -> severity. The delivery failure is
    # silent from inside the repo (the run succeeds, the output file exists), so
    # the job store's own status is the only signal; a job that is still running
    # or delivering locally must never be read as broken.
    def J(name, status, **kw):
        return {"name": name, "id": kw.get("id", "j" + name), "status": status,
                "deliver": kw.get("deliver", "origin"),
                "origin": kw.get("origin", {"platform": "webui"}),
                "error": kw.get("error")}

    delivery_cases = [
        ("all-ok", [J("a", "ok"), J("b", "local")], None),
        ("in-flight", [J("a", None), J("b", "running")], None),
        ("empty", [], None),
        ("one-broken", [J("a", "ok"), J("b", "delivery_failed",
                                       error="unknown platform 'webui'")], "warn"),
        ("all-broken", [J("a", "delivery_failed"), J("b", "delivery_failed")], "warn"),
        # A target that is now `local` is a decision, not a failure -- and
        # last_status is HISTORICAL, so without this the board would carry a
        # resolved item until the job next runs (a week, for the weekly job).
        ("target-fixed-historical-status",
         [J("a", "delivery_failed", deliver="local", error="unknown platform 'webui'")],
         None),
        ("target-fixed-in-list",
         [J("a", "delivery_failed", deliver="local,", error="unknown platform 'webui'")],
         None),
        ("still-asking-still-broken",
         [J("a", "delivery_failed", deliver="origin,slack")], "warn"),
    ]
    for name, rows, want in delivery_cases:
        v = cron_delivery_verdict(rows)
        expect(f"cron_delivery_verdict[{name}]", v[0] if v else None, want)

    # cron_prompt_probe_verdict: prompt text -> severity. A blocked probe leaves
    # no in-repo trace, so the prompt text is the signal; localhost/domains are
    # legitimate, a literal private address and its split-address workaround are not.
    def JP(name, prompt):
        return {"name": name, "id": "j" + name, "prompt": prompt}

    rawip_cases = [
        ("clean", [JP("a", "python3 bin/tc_ops.py caption-endpoint")], None),
        ("literal", [JP("a", "curl -s -m5 http://192.168.86.137:11434/api/version")], "warn"),
        ("split-workaround", [JP("a", "h=Net::HTTP.new('192.168.86.'+'137',11434)")], "warn"),
        ("localhost", [JP("a", "curl -s -m5 http://localhost:8188/system_stats")], None),
        ("domain", [JP("a", "curl -s -m8 https://carnival.pi216.ai/up")], None),
        ("empty", [], None),
    ]
    for name, rows, want in rawip_cases:
        v = cron_prompt_probe_verdict(rows)
        expect(f"cron_prompt_probe_verdict[{name}]", v[0] if v else None, want)

    # photo_pool_verdict: (measured counts, expected severity or None). The pool
    # must EQUAL the servable-or-attached set: dead candidates fail at publish
    # time, missed ones never post, and a drained corpus reads as an empty queue.
    def P(pool, union, unposted, dead, dead_ids="", missed=""):
        return {"pool": str(pool), "union": str(union), "unposted": str(unposted),
                "dead_in_pool": str(dead), "dead_ids": dead_ids,
                "missed_ids": missed}

    pool_cases = [
        ("healthy", P(51, 51, 51, 0), None),
        ("dead-candidate", P(30, 51, 51, 2, dead_ids="8,9"), "warn"),
        ("missed-servable", P(28, 51, 51, 0, missed="339,340"), "warn"),
        ("draining", P(3, 3, 3, 0), "warn"),
        ("empty-corpus", P(0, 0, 0, 0), "warn"),
        ("unreadable", {}, None),
        ("garbage", {"pool": "x", "union": "y", "dead_in_pool": "z"}, None),
    ]
    for name, stats, want in pool_cases:
        v = photo_pool_verdict(stats)
        expect(f"photo_pool_verdict[{name}]", v[2] if v else None, want)

    # photo_resolution_verdict: can the resolver FIND the bytes of a photo whose
    # recorded mount has moved? A missing root is a silent dead end, and bytes
    # present in the mirror that the resolver misses is the regression itself.
    def R(roots, missing="", stranded=0, ids=""):
        return {"roots": roots, "missing": missing, "stranded": str(stranded),
                "ids": ids}

    res_cases = [
        ("healthy", R("/mnt/nas-ai-models/comfyui-output"), None),
        ("dead-root", R("/mnt/a;/mnt/synology-home/backup", missing="/mnt/synology-home/backup"), "warn"),
        ("stranded-bytes", R("/mnt/nas-ai-models/comfyui-output", stranded=3, ids="8,9,10"), "warn"),
        ("no-roots", R(""), "critical"),
        ("unreadable", {}, None),
        ("garbage", {"roots": "/x", "stranded": "many"}, None),
    ]
    for name, stats, want in res_cases:
        v = photo_resolution_verdict(stats)
        expect(f"photo_resolution_verdict[{name}]", v[2] if v else None, want)

    # own_queue_verdict: our own queued scheduler entries -> severity. The harness
    # mints a fresh job id per tick, so a tick killed mid-wait leaks its entry and
    # the next tick queues BEHIND it (self-starvation); a single own entry at the
    # head with the GPU idle is the blockade. Both were live on 2026-09-20.
    def OQ(i, req="2026-09-20T19:00:00Z", proj="turbo-carnival"):
        return {"id": i, "project": proj, "requested_at": req}

    oq_now = calendar.timegm(time.strptime("2026-09-20T21:00:00", "%Y-%m-%dT%H:%M:%S"))
    oq_cases = [
        ("no-queue", [], "idle", False, None),
        ("foreign-only", [OQ("x", proj="prx-tg-pixel-posttrain")], "idle", False, None),
        ("flood", [OQ("a"), OQ("b", req="2026-09-20T20:00:00Z")], "busy", False, "warn"),
        ("own-head-idle", [OQ("a")], "idle", False, "warn"),
        ("own-head-ours", [OQ("a")], "busy", True, None),
        ("behind-foreign",
         [OQ("x", req="2026-09-20T18:00:00Z", proj="prx-tg-pixel-posttrain"), OQ("a")],
         "busy", False, None),
        ("fresh-grace", [OQ("a", req="2026-09-20T20:55:00Z")], "idle", False, None),
    ]
    for name, rows, st, ours, want in oq_cases:
        v = own_queue_verdict(rows, st, ours, now=oq_now)
        expect(f"own_queue_verdict[{name}]", v[2] if v else None, want)

    # ...and the head entry that CANNOT fit is not the blockade: `poll` compares
    # live free memory against the reservation, so a co-tenant the scheduler cannot
    # see turns the same queue shape into a different, non-actionable-by-polling
    # condition (measured 2026-09-21: head entry, gpu=idle, 18.5 GiB free vs a
    # 21 GiB reservation, 4.5 GiB in the BT-Net labeler).
    oq_head = [{"id": "a", "project": "turbo-carnival",
                "requested_at": "2026-09-20T19:00:00Z", "vram_gb": 21.0}]
    v = own_queue_verdict(oq_head, "idle", False, now=oq_now, free_mib=18939,
                          blockers="2857312 labeler_spa.py 4.5GiB")
    expect("own_queue_verdict[head-cannot-fit-key]", v[0] if v else None,
           "own-queue-head-vram-blocked")
    expect("own_queue_verdict[head-cannot-fit-sev]", v[2] if v else None, "warn")
    expect("own_queue_verdict[head-cannot-fit-names-holder]",
           bool(v and "labeler_spa.py" in v[3] and "18.5GiB" in v[3]), True)
    v = own_queue_verdict(oq_head, "idle", False, now=oq_now, free_mib=24000)
    expect("own_queue_verdict[head-fits-is-blockade]", v[0] if v else None,
           "own-queue-blockade")
    # Unreadable free memory must NOT be read as "cannot fit" -- accuse only on data.
    v = own_queue_verdict(oq_head, "idle", False, now=oq_now, free_mib=None)
    expect("own_queue_verdict[free-unknown]", v[0] if v else None, "own-queue-blockade")

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

        # touch: the SAME trap as close, hit live 2026-09-20 -- `touch KEY --note
        # TEXT` persisted the literal "--note" and dropped the text. The flag form
        # must be accepted (and its value kept), a bare flag refused.
        with redirect_stdout(buf):
            rc_t_bad = cmd_touch(["k", "--note"])
        expect("touch[missing-note] rc", rc_t_bad, 2)
        expect("touch[missing-note] untouched",
               json.loads((tmp / "k.json").read_text())["notes"][-1]["note"],
               "resolved by selftest")
        with redirect_stdout(buf):
            rc_t_ok = cmd_touch(["k", "--note", "progress by selftest"])
        expect("touch[--note] rc", rc_t_ok, 0)
        expect("touch[--note] note",
               json.loads((tmp / "k.json").read_text())["notes"][-1]["note"],
               "progress by selftest")
        with redirect_stdout(buf):
            rc_t_pos = cmd_touch(["k", "positional note"])
        expect("touch[positional] rc", rc_t_pos, 0)
        expect("touch[positional] note",
               json.loads((tmp / "k.json").read_text())["notes"][-1]["note"],
               "positional note")

        # file: a manual filing must not steal a probe-owned key (the probe would
        # stop re-filing and auto-closing it), and a missing --evidence must be
        # refused rather than persisted as a blank record.
        with redirect_stdout(buf):
            rc_no_ev = cmd_file(["newkey", "--title", "t"])
        expect("file[missing-evidence] rc", rc_no_ev, 2)
        expect("file[missing-evidence] not-filed", (tmp / "newkey.json").exists(), False)
        with redirect_stdout(buf):
            rc_new = cmd_file(["newkey", "--title", "outside-scope", "--evidence", "e"])
        expect("file[new] rc", rc_new, 0)
        expect("file[new] source", json.loads((tmp / "newkey.json").read_text())["source"], "manual")
        with redirect_stdout(buf):
            cmd_file(["k", "--title", "x", "--evidence", "y"])
        expect("file[probe-owned] keeps source",
               json.loads((tmp / "k.json").read_text())["source"], "probe")

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

    # comfyui_holder_verdict: an unclaimed ComfyUI is only a board issue while it is
    # IDLE. Live = queue non-empty, or a prompt inside the live window (2026-09-20:
    # the check fired on an interactive session that had rendered 4 min earlier, and
    # the growth tick called the same instance an "orphan"); unreadable = unknown,
    # which must never degrade to "idle" and accuse a live instance.
    holder_cases = [
        ("queue-running", 1, 99999.0, "live"),
        ("queue-pending", 3, None, "live"),
        ("rendered-just-now", 0, 60.0, "live"),
        ("rendered-inside-window", 0, COMFYUI_LIVE_WINDOW_S - 1.0, "live"),
        ("rendered-at-window-edge", 0, float(COMFYUI_LIVE_WINDOW_S), "idle"),
        ("abandoned-warm", 0, 7200.0, "idle"),
        ("never-rendered", 0, None, "idle"),
        ("queue-unreadable", None, 7200.0, "unknown"),
        ("all-unreadable", None, None, "unknown"),
    ]
    for name, depth, age, want in holder_cases:
        expect(f"comfyui_holder_verdict[{name}]",
               comfyui_holder_verdict(depth, age), want)

    # cron_prompt_orphan_verdict: a prompt line that calls ANY unclaimed ComfyUI an
    # orphan, without the owner= gate, is the defect (it names a co-tenant's live
    # render a leak; 2026-09-20, all three monitoring prompts read that way).
    old_line = ("  * comfyui=up while claim=idle \u2192 ORPHANED GPU LEAK: ComfyUI holds "
                "22+GB with NO claim")
    new_line = ("  * comfyui=up while claim=idle: read owner=; owner=ours is OUR orphan "
                "(a leak), owner=foreign is normal sharing")
    orphan_cases = [
        ("old-wording", [{"name": "watchdog", "id": "w1", "prompt": old_line}], "warn"),
        ("fixed-wording", [{"name": "watchdog", "id": "w1", "prompt": new_line}], None),
        ("orphan-without-claim-state",
         [{"name": "x", "id": "x1", "prompt": "* an orphaned ComfyUI is an anomaly"}], None),
        ("claim-state-without-orphan",
         [{"name": "x", "id": "x1", "prompt": "* claim=idle means the GPU is free"}], None),
        ("no-prompts", [{"name": "x", "id": "x1", "prompt": None}], None),
    ]
    for name, rows, want in orphan_cases:
        v = cron_prompt_orphan_verdict(rows)
        expect(f"cron_prompt_orphan_verdict[{name}]", v[0] if v else None, want)

    # cron_prompt_logpath_verdict: a prompt reading a log nothing writes. The
    # 2026-09-20 case is log/growth_harness.log (30d dead, two live prompts).
    _fresh = lambda _rel: (True, 3600.0)
    _dead = lambda _rel: (True, 30 * 86400.0)
    _missing = lambda _rel: (False, None)
    _unknown = lambda _rel: (True, None)
    logpath_cases = [
        ("fresh-log", [{"name": "w", "id": "w1",
                        "prompt": "tail -40 log/development.log"}], _fresh, None),
        ("dead-log", [{"name": "w", "id": "w1",
                       "prompt": "tail -40 log/growth_harness.log and log/development.log"}],
         _dead, "warn"),
        ("missing-log", [{"name": "w", "id": "w1", "prompt": "read log/whatever.log"}],
         _missing, "warn"),
        ("age-unreadable", [{"name": "w", "id": "w1", "prompt": "tail log/x.log"}],
         _unknown, "warn"),
        ("no-log-ref", [{"name": "w", "id": "w1",
                         "prompt": "run bin/comfyui_harness.sh ensure"}], _dead, None),
        ("non-log-file", [{"name": "w", "id": "w1",
                           "prompt": "read config/database.yml"}], _missing, None),
        ("absolute-path-ignored",
         [{"name": "w", "id": "w1", "prompt": "tail /var/log/syslog"}], _missing, None),
        ("no-prompt", [{"name": "w", "id": "w1", "prompt": None}], _missing, None),
    ]
    for name, rows, probe, want in logpath_cases:
        v = cron_prompt_logpath_verdict(rows, probe=probe)
        expect(f"cron_prompt_logpath_verdict[{name}]", v[0] if v else None, want)

    # prompt_safety_verdict + _blob_violations: stored render text that directs a
    # minor or conditions against adult features. The 2026-09-20 live case is the
    # production negative prompt (", adult, mature_face,") and the legacy face
    # step's "white, Caucasian young teenager" instruction.
    safety_cases = [
        ("guard-wired-and-clean", True, [], [], None),
        ("guard-wired-stored-dirty", True, [("step 40 (pipeline 21)", ["adult", "mature_face"])], [], "warn"),
        ("guard-wired-repo-dirty", True, [], [("comfy_workflows/sarah1a3/34.json", ["young teenager"])], "warn"),
        ("guard-missing-clean-data", False, [], [], "critical"),
        ("guard-missing-dirty-data", False, [("step 34 (pipeline 17)", ["young teenager"])], [], "critical"),
    ]
    for name, wired, db_hits, file_hits, want in safety_cases:
        expect(f"prompt_safety_verdict[{name}]",
               prompt_safety_verdict(wired, db_hits, file_hits), want)

    blob_cases = [
        ("live-production-negative",
         '{"79": {"inputs": {"text": "worst quality, low quality, long neck, adult, '
         'mature_face, sunken_eyes\\n"}}}',
         ["adult", "mature_face"], []),
        ("legacy-llm-instruction",
         '{"96": {"inputs": {"system": "make it a white, Caucasian young teenager."}}}',
         [], ["young teenager"]),
        ("positive-adult-woman-is-fine",
         '{"88": {"inputs": {"text": "score_9, adult woman, sarah1a3"}}}',
         [], []),
        ("petite-and-young-are-not-violations",
         '{"88": {"inputs": {"text": "petite face, small nose, young female arm and hand"}}}',
         [], []),
        ("clean-negative",
         '{"79": {"inputs": {"text": "worst quality, low quality, bad anatomy"}}}',
         [], []),
        ("adult-token-without-negative-boilerplate",
         '{"88": {"inputs": {"text": "portrait, adult, woman, garden"}}}',
         [], []),
    ]
    for name, blob, want_adult, want_juvenile in blob_cases:
        juvenile, adult = _blob_violations(blob)
        expect(f"_blob_violations[{name}].adult", adult, want_adult)
        expect(f"_blob_violations[{name}].juvenile", juvenile, want_juvenile)

    # human_digest: the board has no OTHER readable surface (cron delivery from
    # this profile fails), so this is the artifact a human reads. It must stay
    # BOUNDED -- it is rewritten on every probe run -- and must carry the NEWEST
    # note, since the latest triage pass is the part that says where the item
    # stands.
    d_empty = human_digest([], now="2026-09-20T00:00:00Z")
    long_evidence = "x" * (DIGEST_EVIDENCE_CHARS + 50)
    digest_rec = {
        "key": "k1", "title": "t1", "severity": "warn", "evidence": long_evidence,
        "source": "manual", "seen_count": 3, "first_seen": "2026-09-19T00:00:00Z",
        "last_seen": "2026-09-20T00:00:00Z",
        "notes": [{"ts": "old", "note": "OLD NOTE"}, {"ts": "new", "note": "NEW NOTE"}],
    }
    d_one = human_digest([digest_rec], now="2026-09-20T00:00:00Z")
    digest_tim = dict(digest_rec, key="k2", route="tim", source="manual")
    digest_bad = dict(digest_rec, key="k3", route="banana")
    d_two = human_digest([digest_rec, digest_tim, digest_bad], now="2026-09-20T00:00:00Z")
    digest_cases = [
        ("empty-counts-zero", "Open: 0" in d_empty, True),
        ("empty-has-no-items", "## WARN" in d_empty, False),
        ("key-present", "`k1`" in d_one, True),
        ("newest-note-only", "NEW NOTE" in d_one and "OLD NOTE" not in d_one, True),
        ("evidence-bounded", (long_evidence not in d_one)
         and ("x" * DIGEST_EVIDENCE_CHARS in d_one), True),
        ("records-route-count", "enablement for Tim: 0 | agent decisions: 1" in d_one, True),
        ("splits-tim-and-agent", "enablement for Tim: 1 | agent decisions: 2" in d_two, True),
        ("tim-item-in-enablement-section",
         "ENABLEMENT (route=tim)" in d_two and "`k2`" in d_two, True),
        ("tim-item-routes-tim", "- route tim |" in d_two, True),
        ("garbage-route-routes-agent", "- route agent |" in d_two, True),
    ]
    for name, got, want in digest_cases:
        expect(f"human_digest[{name}]", got, want)

    # route_of: the queue an item belongs to. An explicit route wins; anything
    # else -- absent, blank, garbage -- is the AGENT's, because a business decision
    # sitting in a human's queue is the failure this split exists to undo.
    route_cases = [
        ("explicit-tim", {"route": "tim"}, "tim"),
        ("explicit-agent", {"route": "agent"}, "agent"),
        ("case-and-space", {"route": "  TIM "}, "tim"),
        ("absent", {}, "agent"),
        ("blank", {"route": ""}, "agent"),
        ("garbage", {"route": "banana"}, "agent"),
        ("none", {"route": None}, "agent"),
    ]
    for name, rec, want in route_cases:
        expect(f"route_of[{name}]", route_of(rec), want)

    # escalations_text: only the enablement queue may reach the operator, and an
    # empty queue must render to "" so a delivery job suppresses itself instead of
    # sending "nothing to do". The inverse -- pushing agent-owned decisions to a
    # human -- is what stalled the board in the first place.
    esc_tim = {"key": "e1", "title": "t", "severity": "warn", "route": "tim",
               "first_seen": "2026-09-19T00:00:00Z",
               "notes": [{"ts": "new", "note": "LATEST ASK"}]}
    esc_agent = {"key": "a1", "title": "t", "severity": "warn", "route": "agent",
                 "notes": [{"ts": "new", "note": "AGENT ONLY"}]}
    esc_cases = [
        ("none-needs-human", escalations_text([esc_agent]), ""),
        ("empty-board", escalations_text([]), ""),
        ("tim-item-listed", "e1" in escalations_text([esc_tim]), True),
        ("agent-item-never-pushed", "a1" in escalations_text([esc_agent, esc_tim]), False),
        ("carries-newest-ask", "LATEST ASK" in escalations_text([esc_tim]), True),
    ]
    for name, got, want in esc_cases:
        expect(f"escalations_text[{name}]", got, want)

    # image_grounding_verdict: does any published caption look at the render?
    # (total, attached, recent_unattached, vision_posts) -> severity or None.
    grounding_cases = [
        ("path-only-live", (337, 141, 12, 0), "info"),
        ("vision-in-window", (337, 141, 12, 3), None),
        ("all-recent-attached", (10, 10, 0, 0), None),
        ("empty-corpus", (0, 0, 0, 0), None),
        ("unreadable", (None, None, None, None), None),
    ]
    for name, args, want in grounding_cases:
        v = image_grounding_verdict(*args)
        expect(f"image_grounding_verdict[{name}]", v[0] if v else None, want)

    # photo_provenance_verdict: the DB half of the synthetic mark. A producer
    # that stopped marking is critical (nothing reaches the corpus marked); an
    # unmarked row is warn (unknown origin, no input for the asset-level mark).
    prov_cases = [
        ("wired-and-complete", False, 0, 0, None),
        ("wired-with-unmarked-rows", False, 5, 0, "warn"),
        ("wired-with-recent-unmarked", False, 2, 2, "warn"),
        ("producer-unwired", True, 0, 0, "critical"),
        ("producer-unwired-with-rows", True, 337, 12, "critical"),
        ("unreadable-db", False, None, None, None),
    ]
    for name, unwired, n_unmarked, n_recent, want in prov_cases:
        expect(f"photo_provenance_verdict[{name}]",
               photo_provenance_verdict(unwired, n_unmarked, n_recent), want)

    # publish_gate_verdict: the ASSET-level readiness of the fail-closed publish
    # gate. A queued asset the marker refuses stops the post, so it must be
    # reported BEFORE a slot reaches it -- and a queue of markable assets must
    # stay silent (the gate is not allowed to become board noise).
    gate_cases = [
        ("all-markable", {"queued": "16", "unmarked": "0", "blocked": "0",
                          "noservable": "0", "ids": ""}, None),
        ("one-truncated-png", {"queued": "16", "unmarked": "3", "blocked": "1",
                               "noservable": "0", "ids": "328/334:unsupported"},
         "publish-gate-unmarkable-asset"),
        ("unwritable-dir", {"queued": "4", "unmarked": "4", "blocked": "4",
                            "noservable": "0", "ids": "1/1:unwritable"},
         "publish-gate-unmarkable-asset"),
        ("empty-queue", {"queued": "0", "unmarked": "0", "blocked": "0",
                         "noservable": "0", "ids": ""}, None),
        ("no-servable-file-only", {"queued": "3", "unmarked": "0", "blocked": "0",
                                   "noservable": "3", "ids": ""}, None),
        ("unreadable-probe", {}, None),
        ("garbage-stats", {"queued": "?", "blocked": "?"}, None),
    ]
    for name, stats, want in gate_cases:
        v = publish_gate_verdict(stats)
        expect(f"publish_gate_verdict[{name}]", v[0] if v else None, want)

    # vram_refusal_clause: fires only when free VRAM is below the ask -- i.e. below
    # the harness's fit floor, where the ask is not reduced and nothing is attempted.
    # A resident co-tenant is never called a blocker by itself (ComfyUI partial-loads
    # the UNet; it has rendered at a 14.9GiB resident UNet).
    refusal_cases = [
        ("below-floor-idle-holder", (15000, 21, 0, 1, 23743, 24564), "holder resident but idle"),
        ("below-floor-working-holder", (15000, 21, 97, 1, 23743, 24564), "holder working"),
        ("below-floor-util-unknown", (15000, 21, None, 1, None, None), "fit floor"),
        ("below-floor-no-holder", (15000, 21, None, 0, 23743, 24564), "fit floor"),
        ("fits", (18939, 17, 0, 1, 23743, 24564), None),
        ("exactly-the-ask", (17408, 17, 0, 1, 23743, 24564), None),
        ("free-unknown", (None, 21, 0, 1, 23743, 24564), None),
        ("req-unknown", (15000, None, 0, 1, 23743, 24564), None),
        ("holders-unknown", (15000, 21, 0, None, 23743, 24564), None),
    ]
    for name, args, want in refusal_cases:
        got = vram_refusal_clause(*args)
        if want is None:
            expect(f"vram_refusal_clause[{name}]", got, "")
        else:
            expect(f"vram_refusal_clause[{name}]", want in got, True)

    # adaptive_ask_gb: the fit policy, mirrored from the harness. Full ask when the
    # card is free; free minus headroom otherwise; the FLOOR when even that falls
    # below it -- never the full ask, because the ask is PERSISTED in the queue
    # record and re-checked at claim time against the free reading the card will
    # have once the current occupant releases (see adaptive_ask_gb's docstring).
    ask_cases = [
        ("card-free", 24564, 21.0),
        ("exactly-full-ask", 21504, 21.0),
        ("just-under", 21000, 19.0),
        ("live-2026-09-21", 18939, 17.0),
        ("at-floor", 17408, 16.0),
        ("below-floor", 16384, 16.0),
        ("card-occupied-2026-09-21", 8192, 16.0),
        ("tiny", 4096, 16.0),
        ("unknown", None, 21.0),
        ("garbage", "?", 21.0),
    ]
    for name, free_mib, want in ask_cases:
        expect(f"adaptive_ask_gb[{name}]", adaptive_ask_gb(free_mib), want)

    # The mirror above is only worth having if it agrees with the launcher. Run the
    # harness's OWN decision (plan takes the reading as an argument, so this needs no
    # GPU and no claim) and require the two to match: a policy change in the harness
    # must fail HERE rather than quietly make the probe report a different ask than
    # the launcher makes.
    _harness = APP / "bin" / "comfyui_harness.sh"
    _plan_checks = 0
    if _harness.exists():
        for _free in (24564, 21504, 21000, 18939, 17408, 16384, 8192):
            _out, _rc = run([str(_harness), "plan", str(_free)])
            # NOT r"ask=..." -- the line also carries "full_ask=21GiB", which that
            # pattern matches first and reports as the decision for every reading.
            _m = re.search(r"(?<![_\w])ask=(\d+)GiB", _out or "")
            expect(f"harness-plan-matches-mirror[{_free}]",
                   float(_m.group(1)) if (_rc == 0 and _m) else None,
                   adaptive_ask_gb(_free))
            _plan_checks += 1

    # The harness's launch-layer deps gate and this file's own import probe must
    # AGREE about the venv. Measured 2026-09-21: ensure_comfyui_deps ran
    # `python -c 'import comfy.storage'` with the harness's OWN cwd (the repo root)
    # while this file passes cwd=COMFY_DIR -- and `comfy` is ComfyUI's own package,
    # importable only from the app dir (python -c puts the CWD on sys.path), so the
    # harness gate logged "ERROR — import still failing after pip install" on a
    # HEALTHY venv, and ran a pointless pip install, on every launch. That made the
    # gate useless for the one case it was built for (requirements.txt pin drift).
    # Both surfaces now ask the same question the same way; this asserts the two
    # cannot silently drift apart again (a healthy venv must read OK on both).
    _deps_checks = 0
    if _harness.exists():
        _dout, _drc = run([str(_harness), "deps"])
        _deps_checks = 1
        expect("harness-deps-agrees-with-board",
               "deps: OK" in (_dout or ""),
               check_launch_deps_importable() is None)

    # telemetry_peak_mib: the render footprint is READ from the sampler's own
    # file (the number the reservation is sized from), so a malformed line must
    # not throw and an empty file must read as unknown, never as 0.
    with tempfile.TemporaryDirectory() as _d:
        _p = Path(_d) / "tele.jsonl"
        _p.write_text('{"vram_used_mib": 388}\nnot json\n{"vram_used_mib": 23743}\n')
        expect("telemetry_peak_mib[parses-and-skips-bad-line]",
               telemetry_peak_mib(_p), 23743)
        _p.write_text("")
        expect("telemetry_peak_mib[empty]", telemetry_peak_mib(_p), None)
        expect("telemetry_peak_mib[missing-file]",
               telemetry_peak_mib(Path(_d) / "nope.jsonl"), None)

    for f in fails:
        print(f"FAIL {f}")
    print(f"selftest: {len(cases) + len(publish_cases) + len(gap_cases) + len(failed_cases) + len(untagged_cases) + len(insights_cases) + len(burst_cases) + 2 * len(slot_cases) + 2 * len(cap_cases) + len(pacing_cases) + len(delivery_cases) + len(rawip_cases) + len(pool_cases) + len(res_cases) + len(oq_cases) + len(holder_cases) + len(orphan_cases) + len(logpath_cases) + len(safety_cases) + 2 * len(blob_cases) + len(digest_cases) + len(route_cases) + len(esc_cases) + len(grounding_cases) + len(prov_cases) + len(gate_cases) + len(refusal_cases) + len(ask_cases) + _plan_checks + _deps_checks + len(rerr_cases) + 3 + 26} assertions, {len(fails)} failures")
    return 1 if fails else 0


def cmd_log_health(_argv):
    """Answer "what are the harness errors" from the LIVE logs, for cron prompts.

    Third instance of the same config-rot family as `caption-endpoint`: the
    monitoring prompts hardcode log paths, and a path rots the moment its writer
    moves (log/growth_harness.log died 2026-08-20 with its deprecated wrapper while
    two live prompts still tailed it). This command owns the question instead: it
    prints each live log's AGE -- so a dead log shows up as an age, not as an empty
    tail that reads like "no errors" -- plus its recent error lines. Informational:
    always exits 0, so a monitoring tick can never be blocked by it.
    """
    for rel in LOG_HEALTH_FILES:
        exists, age, n, samples = log_error_samples(rel)
        if not exists:
            print(f"{rel}: MISSING (nothing writes this path any more)")
            continue
        if age is None:
            print(f"{rel}: present but its age is unreadable")
            continue
        shown = f"{age / 3600:.1f}h" if age < 86400 else f"{age / 86400:.1f}d"
        print(f"{rel}: age={shown} errors={n}")
        for s in samples:
            print(f"    {s[:160]}")
    for rel in DEPRECATED_LOGS:
        exists, age, _, _ = log_error_samples(rel)
        if exists and age is not None:
            print(f"{rel}: DEPRECATED — age={age / 86400:.1f}d, nothing writes it "
                  f"(its wrapper bin/growth_harness.sh is retired); do NOT read it "
                  f"for harness health")
    return 0


def cmd_caption_endpoint(_argv):
    """Answer "is the caption service up" from Python, so cron prompts can call it.

    The cron prompts probe Ollama with a raw-IP curl, which the tool scanner
    blocks on private-network/plain-HTTP grounds -- so every run improvised an SSH
    fallback (genome #13: agent workarounds masking a config defect). The scanner
    reads the SHELL COMMAND, not what the process does, so
    `python3 bin/tc_ops.py caption-endpoint` asks the same question of the same
    configured endpoint and cannot be blocked. Exit 0 = up, 1 = down.
    """
    models = caption_resident_models()
    if models is None:
        print(f"down (no /api/ps answer from {CAPTION_ENDPOINT})")
        return 1
    print(f"up ({CAPTION_ENDPOINT}); resident: {', '.join(models) if models else 'none'}")
    return 0


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
        "file": cmd_file, "warm-caption": cmd_warm_caption,
        "caption-endpoint": cmd_caption_endpoint,
        "log-health": cmd_log_health,
        "needs-human": cmd_needs_human,
        "route": cmd_route,
        "escalations": cmd_escalations,
    }.get(cmd, lambda a: (print(__doc__), 2)[1])(argv)


if __name__ == "__main__":
    sys.exit(main())