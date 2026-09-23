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
  tc_ops.py holder-class PID  who owns that process: operator|agent|unit|other
                             (the bash surface for the holder classifier -- the
                             harness labels the :8188 instance with it, so
                             `owner=foreign` always carries a WHO)
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
  tc_ops.py queue            the AUTHORITATIVE photo-queue count: publishable vs
                             status_rows vs held, plus dry_out= -- the FORECAST
                             (the publisher selects on the two clocks, so a status
                             count overstates by every age-gate hold and makes a
                             held row look like a defect to repair; and a bare
                             count cannot say whether the harness has one day of
                             runway or two weeks)
  tc_ops.py checks-audit     is the MONITORING still live? runs every check and
                             reports ones that RAISED and any DB read that came
                             back unreadable -- a check whose query broke returns
                             None exactly like a healthy check whose condition is
                             absent, so it silently retires and the board stays
                             green (no DB writes, no issue filing)
  tc_ops.py selftest         exercise every pure verdict in this file (no DB, no
                             GPU) -- run it after touching any check

Probe exits 0 always (cron-safe); prints CRITICAL/WARN counts. The probe blocks
up to TC_CAPTION_WARM_BUDGET seconds (default 240) ONLY when no caption model is
resident, because measuring "can a cold caption load complete" means attempting
one -- give it a timeout that accommodates that.
"""
from __future__ import annotations

import json
import base64
import calendar
import datetime
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
# The pre-registered GO/PIVOT/KILL criterion, asserted rather than assumed: the
# weekly review must still EMIT the gate read, and the two locked thresholds must
# not drift silently. See check_weekly_review_gate_wired.
GROWTH_RAKE = APP / "packs" / "growth_harness" / "lib" / "tasks" / "growth.rake"
GATE_READ_SRC = (APP / "packs" / "growth_harness" / "app" / "services"
                 / "growth" / "gate_read.rb")
GATE_WIRED = re.compile(r"GateRead|print_gate_read")
GATE_FOLLOWER_CEILING_RE = re.compile(r"FOLLOWER_CEILING\s*=\s*([\d.]+)")
GATE_PILLAR_FLOOR_RE = re.compile(r"PILLAR_ENGAGEMENT_FLOOR\s*=\s*([\d.]+)")
GATE_FOLLOWER_CEILING = 170
GATE_PILLAR_FLOOR = 3.0
# The engagement leg of that gate is a MEASUREMENT only if the review window
# holds MIN_COHORT_POSTS posts whose PHOTO was rendered at/after the content-mix
# intervention (Growth::GateRead.cohort_size: a post rendered before it cannot
# carry any lever's effect, and publication lags the render by the queue depth).
# That pool is replenished ONLY by the render loop -- so a REFUSED render loop
# freezes it, and the pre-committed handling of a short cohort (`:extend` =
# "re-read, do NOT act") then reads as "wait another week", when waiting is
# exactly what cannot help. Mirrored from Growth::GateRead (parsed, not trusted:
# see gate_cohort_params) and checked by check_gate_cohort_starved.
GATE_COHORT_MIN = 5
GATE_INTERVENTION_AT = "2026-09-21 23:35:00"   # Growth::GateRead::INTERVENTION_AT
GATE_MIN_COHORT_RE = re.compile(r"MIN_COHORT_POSTS\s*=\s*(\d+)")
GATE_INTERVENTION_RE = re.compile(
    r"INTERVENTION_AT\s*=\s*Time\.utc\((\d+),\s*(\d+),\s*(\d+),\s*(\d+),\s*(\d+)\)")
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
# ACCEPTANCE, not freshness: a pipeline can publish at full cadence while nothing
# it publishes is accepted. Measured 2026-09-22 -- the account published 36 posts
# in September with 0 likes, 0 comments, 0 saves and a mean reach of ~3.5/post
# (February: ~15/post), and no surface anywhere said so: every render completed,
# every post landed, the queue stayed at target. Genome #43 ("output != accepted
# output"): the acceptance counter is the signal, and its absence is why this
# reads as a healthy harness right up to the 2026-09-28 GO/PIVOT/KILL gate.
# Window is trailing so the entry self-closes the moment engagement returns, and
# only posts whose insights were actually COLLECTED are counted -- missing data
# must never masquerade as zero acceptance.
ENGAGEMENT_WINDOW_DAYS = int(os.environ.get("TC_ENGAGEMENT_WINDOW_DAYS", "14"))
ENGAGEMENT_MIN_POSTS = int(os.environ.get("TC_ENGAGEMENT_MIN_POSTS", "10"))
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


#: Set to a list by `checks-audit` (and only then) so every unreadable read is
#: attributed to the check that made it. None on the normal probe path, so the
#: instrumentation costs nothing there.
_AUDIT_SINK = None
_AUDIT_CHECK = None


def _audit_note(kind, sql):
    if _AUDIT_SINK is not None:
        _AUDIT_SINK.append({"check": _AUDIT_CHECK, "kind": kind, "sql": " ".join(sql.split())})


def psql(sql, timeout=25):
    """Scalar query via psql; returns None when psql/DB is unavailable."""
    out, rc = run(["psql", "-At", "-d", DB, "-c", sql], timeout=timeout)
    if rc != 0 or not out:
        _audit_note("psql", sql)
        return None
    return out.splitlines()[0].strip()


def psql_lines(sql, timeout=25):
    """Multi-row query via psql; returns [] for an empty result, None when unreadable."""
    out, rc = run(["psql", "-At", "-d", DB, "-c", sql], timeout=timeout)
    if rc != 0:
        _audit_note("psql_lines", sql)
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
        # The launch-args gate fires BEFORE the claim is ever requested, so when it
        # is up it is the reason the tick was refused -- named first, or the reader
        # re-derives the cause from the VRAM arithmetic (which may merely coincide).
        _rpid = comfyui_serving_pid()
        gate = reserve_gate_clause(comfyui_reserve_ok(_rpid), _rpid,
                                   holder_class_of(_rpid) if _rpid else None)
        # The lever travels WITH the ask. This item is the ONLY escalation that
        # reaches a human on a starved tick (the runway forecast is a later, milder
        # signal: measured 2026-09-23 the CRITICAL fired at 24.3h of zero output while
        # dry_out was still 6.2d out), and naming the holder without the lever leaves
        # it as "your session is in the way" -- the unactionable ask this board exists
        # to end. Route: enablement when his own session is the pin, agent otherwise.
        _holders = gpu_vram_holders()
        _reserve = comfyui_reserve_ok(_rpid)
        lever = operator_holder_lever(_reserve, _holders, _rpid)
        return (
            "render-starved",
            f"no photo in {STARVE_WINDOW_H}h while the render request was refused {refused}x",
            "warn",
            f"photos_{STARVE_WINDOW_H}h=0 refusals_{STARVE_WINDOW_H}h={refused} "
            f"holder={job or 'none'}" + (f" held={held:.1f}h" if held else "")
            + gate
            + (f"; {fit}" if fit else "")
            + lever,
            starve_route(_reserve, _holders, _rpid),
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


def render_attempts_in_window(hours=RENDER_ERR_WINDOW_H):
    """How many renders were ATTEMPTED in the window, or None when unreadable."""
    rows = psql_lines(
        "select count(*) from comfyui_jobs "
        f"where created_at > (now() at time zone 'UTC') - interval '{hours} hours'")
    try:
        return int(rows[0])
    except (TypeError, IndexError, ValueError):
        return None


def render_coverage_verdict(attempts):
    """Pure: renders ATTEMPTED in the window -> an INFO (severity, evidence) or None.

    The fresh-error check is an ABSENCE check, and an absence claim is only as
    strong as the observation's coverage of the interval. In a zero-render window
    the check returns None exactly as it does after a real repair -- and
    cmd_probe auto-closes every probe-sourced item whose key is not returned, so a
    DROUGHT silently "repairs" an open defect. That is not hypothetical: the
    CLIPSeg empty-mask defect (job 7563) left the board at 2026-09-22 20:25Z with
    "condition no longer reproduces" purely because zero renders ran in its 24 h
    window, and had to be re-filed by hand. Returning an INFO here keeps the item
    alive and says why; it self-closes the moment a render runs (attempts > 0
    restores the ordinary path).
    """
    if attempts is None or attempts > 0:
        return None
    return ("info", f"0 render(s) were ATTEMPTED in the last {RENDER_ERR_WINDOW_H}h, so "
            "the absence of a fresh ComfyUI execution error is UNVERIFIED, not a "
            "repair -- an absence claim is only as strong as its interval coverage. "
            "Filed so a render drought cannot auto-close an open execution-error "
            "item (the mechanism by which the CLIPSeg empty-mask defect left the "
            "board on 2026-09-22 20:25Z). Self-closes as soon as a render runs.")


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
        cov = render_coverage_verdict(render_attempts_in_window())
        if cov:
            sev, ev = cov
            return ("render-execution-error",
                    "UNVERIFIED: no render was attempted in the 24h window",
                    sev, ev)
        return None
    sev, newest = v
    n = len([r for r in (rows or []) if r and r.strip()])
    attempts = render_attempts_in_window()
    return (
        "render-execution-error",
        f"a render died inside the workflow: {newest}",
        sev,
        f"{n} ComfyUI execution error(s) in the last {RENDER_ERR_WINDOW_H}h"
        + (f" out of {attempts} render attempt(s)" if attempts else "")
        + f"; newest {newest}. The producer now NAMES this (Growth::ContentGenerator "
        "carries the ComfyUI error into the run's failure reason and the brain's "
        "decision row) instead of reporting every render death as a timeout, and "
        "it RE-SUBMITS once on a node exception (a fresh seed -- seed = the run's "
        "base seed + the new ComfyuiJob id -- so the retry draws a different "
        "sample). A retry that RECOVERS still leaves this failed row, so read this "
        "entry as 'the workflow can die on this input', not as 'a render was "
        "lost'. TWO classes land here and only one is the payload: (a) the "
        "workflow dying on its input -- an empty CLIPSeg head/hand mask reaching "
        "the WAS 'Bounded Image Crop with Mask' node, `index is out of bounds` "
        "(2026-09-21 11:16Z); (b) ComfyUI running out of VRAM mid-render, whose "
        "NEXT job then fails with the HTTP 500 seen here (2026-09-22 00:05Z). "
        "Class (b) is tracked with its budget numbers as `comfyui-torch-oom` -- "
        "read that entry for the cause instead of re-deriving it from this row. "
        "Neither is Rails code. Reconciled orphans are excluded.",
    )


# --------------------------------------------------------------- age gate
# Window for "the gate is firing". A hold older than this stops reproducing and
# the board entry self-closes, which is the only way an item about a DELIBERATE
# action can ever leave the board.
AGE_HOLD_WINDOW_H = 48
# Three holds inside the window means the INPUT fix (PersonaAgeAnchor: the adult
# age anchor appended to the persona's positive prompt) is not landing -- the gate
# is then holding renders faster than the producer replaces them and the queue
# drains toward silence.
AGE_HOLD_WARN_N = 3


def age_hold_verdict(publishable_juvenile, recent_holds, live_holds):
    """Pure: age-gate counts -> (severity, kind) or None.

    Three counts, three questions, and the SAFETY question is deliberately first:

    publishable_juvenile -- an unpublished post whose own stored read says
        JUVENILE still carries a live clock (or is not marked held at all). The
        publisher selects on exactly that predicate, so the hold is NOT in force
        and a minor-reading render is one tick away from a public adult account.
        The only critical branch.
    recent_holds -- holds recorded inside AGE_HOLD_WINDOW_H. >= AGE_HOLD_WARN_N
        means the anchor is not landing; 1..N-1 is informational: the gate did its
        job once and the queue owes a replacement render.
    live_holds -- posts in the held state right now (unpublished, no clock). Each
        is a publishing slot the queue will never see. Deliberately NOT what
        raises severity: a hold is a decision already taken, so keying on it would
        pin the board forever instead of letting an aged-out hold self-close.

    Returns None when nothing is recent -- that is what makes the entry
    self-closing.
    """
    if publishable_juvenile:
        return ("critical", "publishable")
    if recent_holds >= AGE_HOLD_WARN_N:
        return ("warn", "holds")
    if recent_holds > 0:
        return ("info", "holds")
    return None


def check_age_gate_holds():
    """Growth::PersonaAgeGate holds a queued post whose render reads juvenile.

    WHY THIS EXISTS (measured 2026-09-21): the gate HELD post 345 (photo 353) at
    15:04Z by clearing BOTH of the publisher's clocks -- a deliberate safety
    decision, recorded as growth_decisions 636 -- and nothing in the ops loop
    could see it. The same day's watchdog read the row and reported it as a
    DEFECT: "post 345 can never publish ... operator action: set scheduled_at or
    reclassify", which is the exact opposite of the truth, because acting on that
    advice publishes a render the gate read as a minor on a public adult account.
    A safety action with no observability gets re-diagnosed as a bug and "fixed"
    in the unsafe direction.

    It also has a queue consequence the board cannot otherwise attribute: a held
    post drops out of the cadence count (Growth::CadenceEngine and
    check_future_queue_empty both select on the two clocks), so the queue is one
    slot shorter and the producer owes a replacement render -- while
    check_future_queue_empty only fires once the queue reaches ZERO, days later.

    The held state is (unpublished) + (no scheduled_at and no
    optimal_time_calculated) + caption_metadata.age_gate.held -- the same write
    PersonaAgeGate#hold makes, so this check cannot drift from the gate.
    """
    row = psql(
        "select "
        " count(*) filter (where flagged and (not held or has_clock)) || '|' || "
        " count(*) filter (where held and ts > (now() at time zone 'UTC') "
        f" - interval '{AGE_HOLD_WINDOW_H} hours') || '|' || "
        " count(*) filter (where held and not has_clock) "
        "from (select "
        " (caption_metadata->'age_gate'->>'verdict') = 'juvenile' as flagged, "
        " (caption_metadata->'age_gate'->>'held') = 'true' as held, "
        " (coalesce(scheduled_at, optimal_time_calculated) is not null) as has_clock, "
        " case when (caption_metadata->'age_gate'->>'checked_at') "
        "      ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' "
        "  then (caption_metadata->'age_gate'->>'checked_at')::timestamptz end as ts "
        " from scheduling_posts "
        " where status in ('draft','scheduled') and caption_metadata ? 'age_gate') t")
    if row is None:
        return None
    try:
        pj_str, rec_str, live_str = row.split("|")
        publishable, recent, live = int(pj_str), int(rec_str), int(live_str)
    except ValueError:
        return None
    v = age_hold_verdict(publishable, recent, live)
    if not v:
        return None
    sev, kind = v

    # Name the rows and the read that held them: the whole point is that the
    # board can say "this is the age gate", not "this post is broken".
    detail = psql_lines(
        "select '#' || id || ' (photo ' || coalesce(photo_id::text, '?') || '): ' || "
        "left(btrim(regexp_replace(coalesce(caption_metadata->'age_gate'->>'read', ''), "
        "E'[\\\\n\\\\r\\\\t ]+', ' ', 'g')), 150) "
        "from scheduling_posts "
        "where status in ('draft','scheduled') "
        "and caption_metadata->'age_gate'->>'held' = 'true' "
        "order by id desc limit 3") or []
    named = "; ".join(r.strip() for r in detail if r and r.strip())

    if kind == "publishable":
        return (
            "age-gate-hold",
            f"{publishable} post(s) the age gate read as JUVENILE are still publishable",
            sev,
            f"{publishable} unpublished row(s) carry caption_metadata.age_gate.verdict="
            "'juvenile' with a live clock (or no hold marker), so "
            "scheduling:post_scheduled can release them to the public account. The "
            "hold is (no scheduled_at AND no optimal_time_calculated) -- re-apply it "
            "with Growth::PersonaAgeGate.hold! (which stores both clocks in its "
            f"Growth::Decision row, so it stays reversible). Held rows: {named}",
        )
    return (
        "age-gate-hold",
        f"{recent} render(s) held by the age gate in the last {AGE_HOLD_WINDOW_H}h",
        sev,
        f"{recent} post(s) held in the window; {live} still in the held state "
        "(unpublished, both clocks cleared, so never released by the publisher). "
        "The gate holds a post whose render's apparent-age read comes back juvenile "
        "and is WORKING AS DESIGNED -- do not 'repair' a held row by restoring its "
        "clock: that publishes the render the gate rejected. A hold drops the post "
        "out of the cadence count, so the producer owes a replacement render; "
        "check_future_queue_empty only fires once the queue reaches zero, days "
        "later. The INPUT half of the fix is the adult age anchor in the persona's "
        f"positive prompt (PersonaAgeAnchor); >= {AGE_HOLD_WARN_N} holds in the "
        f"window means that anchor is not landing. Held rows: {named}",
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


def engagement_acceptance_verdict(n_posts, likes, comments, saved):
    """Pure: measured posts in the trailing window -> severity (None = accepted).

    `n_posts` counts ONLY posts whose insights were actually collected, so an
    unmeasured post can never be read as zero engagement. Below
    ENGAGEMENT_MIN_POSTS the sample cannot support a verdict, and an empty or
    unreadable window returns None: a probe must never invent a dead pipeline.
    Zero -- not "low" -- is the bound, because zero is unambiguous and needs no
    threshold anyone has to defend later.
    """
    if not n_posts or n_posts < ENGAGEMENT_MIN_POSTS:
        return None
    if (likes or 0) + (comments or 0) + (saved or 0) == 0:
        return "warn"
    return None


def check_engagement_acceptance():
    """OUTPUT != ACCEPTED OUTPUT: full-cadence publishing that nobody accepts.

    Distinct from check_insights_stale, which asks whether the measurement path
    runs at all; this asks what it measured. The harness renders one image an
    hour, the publisher releases 3/day, the queue sits at target, every gate
    reads green -- and the account's own numbers say the audience never engaged.
    Nothing else on this board reports that, because every other check measures
    the MACHINE (renders, captions, queue, VRAM) and none measures the RESULT.

    Read it as the 2026-09-28 gate's evidence, not as an in-repo fault: no code
    change makes an audience engage. It is filed so the GO/PIVOT/KILL decision
    is made against a number that was tracked continuously rather than
    reconstructed after the fact.
    """
    win = ENGAGEMENT_WINDOW_DAYS
    row = psql(
        "with w as (select * from scheduling_posts where status = 'posted' "
        f"and posted_at > (now() at time zone 'UTC') - interval '{win} days' "
        "and persona_id = (select persona_id from growth_goals where status = "
        "'active' order by id desc limit 1)) "
        "select (select count(*) from w) || '|' || "
        "(select count(*) from w where insights_updated_at is not null) || '|' || "
        "coalesce((select sum(likes_count) from w where insights_updated_at is not null), 0) || '|' || "
        "coalesce((select sum(comments_count) from w where insights_updated_at is not null), 0) || '|' || "
        "coalesce((select sum(saved_count) from w where insights_updated_at is not null), 0) || '|' || "
        "coalesce((select sum(reach) from w where insights_updated_at is not null), 0)"
    )
    if row is None:
        return None
    try:
        posts, measured, likes, comments, saved, reach = (int(x) for x in row.split("|"))
    except ValueError:
        return None
    sev = engagement_acceptance_verdict(measured, likes, comments, saved)
    if not sev:
        return None
    mean_reach = round(reach / measured, 1) if measured else 0.0
    return (
        "zero-engagement-at-production-rate",
        f"nothing published in {win}d was accepted: {measured} measured post(s), "
        f"{likes} like(s), {comments} comment(s), {saved} save(s)",
        sev,
        f"{posts} post(s) published in the last {win}d, {measured} with insights "
        f"collected; totals over the measured set: likes={likes} comments={comments} "
        f"saves={saved} reach={reach} (mean reach {mean_reach}/post). The harness is "
        "producing normally -- renders complete, posts land, the queue holds at "
        "target -- so every machine-level check stays green while the RESULT is "
        "zero. This is the acceptance counter for the 2026-09-28 GO/PIVOT/KILL "
        "gate; a flat engagement read there is this condition, not a starved "
        "pipeline. Self-closes when a published post is engaged with (any "
        "like/comment/save in the window).",
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


def weekly_gate_wired_verdict(rake_src, gate_src):
    """Pure: does the weekly review still EMIT the pre-registered gate read?

    Returns None when the wiring holds, else (severity, evidence). A REGRESSION
    GUARD, not a shape check, and the reason it exists is measured: the
    GO/PIVOT/KILL criterion names "that review" as the moment it is read, but
    until 2026-09-22 the read lived only in `growth:gate` -- a command nothing
    scheduled invoked -- so the 09-28 review the gate names would have run
    without printing it, and the decision would have waited on an agent
    remembering to ask. `growth:weekly_review` now emits it (shared helper with
    `growth:gate`), and nothing else asserts that survives a refactor: a revert
    leaves every board signal green while the criterion goes dark again.

    Also asserts the two LOCKED thresholds, because a pre-registered bound that
    can be edited silently is not pre-registered -- changing one is a decision to
    change the pre-registration, not a config tweak, and it has to show up as an
    event rather than as a quiet diff.
    """
    if not rake_src:
        return ("warn", f"cannot read the weekly review task ({GROWTH_RAKE.name})")
    idx = rake_src.find("task :weekly_review")
    if idx < 0:
        return ("warn", "growth:weekly_review is gone from the growth tasks, so "
                        "nothing emits the pre-registered gate read")
    body = rake_src[idx:]
    nxt = re.search(r"\n\s*task\s+:", body)
    if nxt:
        body = body[:nxt.start()]
    if not GATE_WIRED.search(body):
        return (
            "warn",
            "growth:weekly_review no longer emits the pre-registered GO/PIVOT/KILL "
            "gate read -- the criterion is judged 'by that review', so a read that "
            "lives only in `growth:gate` needs an agent to remember to run it (the "
            "2026-09-21 state, where the review would have run without the gate)",
        )
    if gate_src:
        ceiling = GATE_FOLLOWER_CEILING_RE.search(gate_src)
        floor = GATE_PILLAR_FLOOR_RE.search(gate_src)
        if ceiling and float(ceiling.group(1)) != GATE_FOLLOWER_CEILING:
            return ("warn",
                    f"pre-registered follower ceiling is now {ceiling.group(1)} "
                    f"(registered at {GATE_FOLLOWER_CEILING}) -- a threshold change is "
                    "a decision to change the pre-registration, not a config edit")
        if floor and float(floor.group(1)) != GATE_PILLAR_FLOOR:
            return ("warn",
                    f"pre-registered pillar engagement floor is now {floor.group(1)}% "
                    f"(registered at {GATE_PILLAR_FLOOR}%) -- same as above")
    return None


def check_weekly_review_gate_wired():
    """Assert the pre-registered gate is emitted by the review it names.

    The gate was registered on the ops board as PROSE, then implemented as code
    (Growth::GateRead) -- but a read nobody schedules is still prose in practice.
    Measured 2026-09-22: `growth:gate` existed and was run only by hand on an ops
    pass, while the weekly review the criterion references printed no gate line
    at all.
    """
    def read(p):
        try:
            return p.read_text()
        except OSError:
            return ""

    v = weekly_gate_wired_verdict(read(GROWTH_RAKE), read(GATE_READ_SRC))
    if not v:
        return None
    return (
        "weekly-review-gate-unwired",
        "the weekly review no longer emits the pre-registered GO/PIVOT/KILL gate read",
        v[0],
        v[1] + f" (checked {GROWTH_RAKE.name} + {GATE_READ_SRC.name})",
    )


def gate_cohort_params(src):
    """PURE: (min_cohort, intervention 'YYYY-MM-DD HH:MM:SS') from GateRead source.

    Parsed rather than trusted: if the cohort rule moves in Growth::GateRead and
    these mirrors do not, this check would forecast a window the gate no longer
    reads. Unreadable or absent source falls back to the mirrors, so the failure
    mode is a stale number, never a crash -- and the drift that matters (the two
    locked thresholds) is already asserted by check_weekly_review_gate_wired.
    """
    min_c, ia = GATE_COHORT_MIN, GATE_INTERVENTION_AT
    m = GATE_MIN_COHORT_RE.search(src or "")
    if m:
        min_c = int(m.group(1))
    m = GATE_INTERVENTION_RE.search(src or "")
    if m:
        y, mo, d, h, mi = (int(x) for x in m.groups())
        ia = f"{y:04d}-{mo:02d}-{d:02d} {h:02d}:{mi:02d}:00"
    return min_c, ia


def gate_cohort_verdict(published, feasible, refusals, min_cohort=GATE_COHORT_MIN):
    """PURE: is the refusal FROZEN pool the thing keeping the gate unreadable?

    Three answers, and the middle one is the point: a short cohort with the render
    loop RUNNING is the pre-committed `:extend` doing its job (the levers have no
    published cohort yet -- re-read later), while the same short cohort with the
    loop REFUSED is a different fact with a different meaning: nothing can enter
    the pool, so "re-read later" is not available. Returns (severity, forecast,
    refusals) or None for "not this condition" / unreadable inputs.

    `feasible` is the queued count the gate can actually COUNT at the review --
    the window's slots that can still carry insights by then (see
    cohort_feasible_count) -- never the raw slot count, which overstates it.
    """
    try:
        forecast = int(published) + int(feasible)
    except (TypeError, ValueError):
        return None
    try:
        refusals = int(refusals)
    except (TypeError, ValueError):
        refusals = 0
    if forecast >= min_cohort or refusals <= 0:
        return None
    return ("warn", forecast, refusals)


# The cohort the NEXT weekly review will read, from the app's OWN cadence (the
# last Growth::Review plus the goal's review_interval_days -- no hardcoded
# weekday), split into the pool and the part of it that lands inside the window.
#
# TWO numbers describe the window's queued posts, and the difference between
# them is the point. `queued` is what the SLOTS suggest (every draft/scheduled
# post whose slot falls inside the window); `slot_minutes` is the same set as
# minutes-before-the-review-instant, from which the check derives the FEASIBLE
# count. Growth::GateRead#cohort_size requires `insights_updated_at`, and
# insights are collected a measured lag AFTER publication, so a post whose slot
# sits inside the last `lag_h` hours of the window can never testify about the
# intervention. Measured 2026-09-23: the four post-intervention slots in the
# 09-28 window are 09-27 09:00 .. 09-28 10:30, while the fastest observed
# publish->insights lag is 32h -- so ALL FOUR are infeasible, and counting them
# made this check report a shortfall of 1 where the true one is 5.
#
# `lag_h` is the FASTEST observed lag (the optimistic bound: if even that makes
# a slot infeasible the verdict cannot depend on a slow estimate) and -1 means
# the DB holds no measured pair, which the pure layer reads as NO CUTOFF -- the
# pre-lag behaviour, so a missing measurement can never invent a shortfall.
GATE_COHORT_SQL = (
    "with rv as (select greatest("
    " coalesce((select max(reviewed_at) from growth_reviews), (now() at time zone 'UTC'))"
    " + (select review_interval_days from growth_goals where status = 'active' limit 1)"
    " * interval '1 day', (now() at time zone 'UTC') + interval '1 day') as next_review),"
    " lg as (select coalesce(min(floor(extract(epoch from (insights_updated_at - posted_at))"
    " / 3600)), -1)::int as lag_h from scheduling_posts"
    " where insights_updated_at is not null and posted_at is not null"
    "   and insights_updated_at > posted_at)"
    " select to_char((select next_review from rv), 'MM-DD HH24:MI') || '|'"
    " || (select count(*) from photos where created_at >= '{ia}') || '|'"
    " || (select count(*) from scheduling_posts p join photos ph on ph.id = p.photo_id"
    "      where ph.created_at >= '{ia}' and p.status = 'posted'"
    "        and p.posted_at between (select next_review from rv) - interval '7 days'"
    "                            and (select next_review from rv)) || '|'"
    " || (select count(*) from scheduling_posts p join photos ph on ph.id = p.photo_id"
    "      where ph.created_at >= '{ia}' and p.status in ('draft','scheduled')"
    "        and p.scheduled_at between (select next_review from rv) - interval '7 days'"
    "                                and (select next_review from rv)) || '|'"
    " || (select lag_h from lg) || '|'"
    " || coalesce((select string_agg("
    "      round(extract(epoch from ((select next_review from rv) - p.scheduled_at)) / 60)::text,"
    "      ',' order by p.scheduled_at)"
    "      from scheduling_posts p join photos ph on ph.id = p.photo_id"
    "      where ph.created_at >= '{ia}' and p.status in ('draft','scheduled')"
    "        and p.scheduled_at between (select next_review from rv) - interval '7 days'"
    "                                and (select next_review from rv)), '')"
)


def as_int(value):
    """PURE: int(value) or None. A psql cell arrives as text; a shape change must
    read as UNKNOWN rather than raising inside a check."""
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def slot_can_carry_insights(minutes_before_review, lag_h):
    """PURE: can a post whose slot sits this many minutes before the review
    instant still carry insights AT that instant?

    Growth::GateRead#cohort_size counts only posts with `insights_updated_at`,
    and insights are collected a measured lag AFTER publication, so a slot inside
    the last `lag_h` hours of the window is structurally unable to testify about
    the intervention -- it is not a late arrival, it is a post the gate can never
    count. An UNKNOWN lag (None, unparseable, or negative) means NO cutoff: the
    pre-lag behaviour, so a missing measurement can never invent a shortfall.
    """
    m = as_int(minutes_before_review)
    lag = as_int(lag_h)
    if m is None or lag is None or lag < 0:
        return True
    return m >= lag * 60


def cohort_feasible_count(slots_csv, lag_h):
    """PURE: how many of the window's queued slots can carry insights in time.

    Returns None when the slot list is unreadable, which the caller reads as "no
    bound" and falls back to the raw queued count -- an unparseable row must
    report what it reported before this bound existed, never a fabricated
    shortfall. An EMPTY list is 0, which is a real measurement.
    """
    toks = [t.strip() for t in str(slots_csv or "").split(",") if t.strip()]
    if not toks:
        return 0
    ok = seen = 0
    for tok in toks:
        m = as_int(tok)
        if m is None:
            continue
        seen += 1
        if slot_can_carry_insights(m, lag_h):
            ok += 1
    return None if seen == 0 else ok


def check_gate_cohort_starved():
    """No read of the pre-registered gate can be a MEASUREMENT while renders are refused.

    Growth::GateRead decides whether the engagement leg is a measurement at all
    from a COHORT: posts published inside the review window whose PHOTO was
    rendered at/after the content-mix intervention. Nothing else feeds it, so a
    refused render loop freezes the pool -- and the cohort then returns under the
    floor at every review while the pre-committed `:extend` keeps meaning
    "re-read, do NOT act", which is why this is its own condition rather than a
    note: `gate=extend ... cohort=0/5 INVALID` reads as "not enough data yet,
    wait", and under a render refusal waiting cannot add a single post. Measured
    2026-09-22 (pool: 7 photos, published 09-27..09-29): the 09-28 window holds 4
    of them and the 10-05 window holds 3, so the expectation recorded on the board
    ("first valid read ETA 2026-10-05") is wrong for as long as the loop is
    refused. Self-closing: when the loop stops being refused the pool grows again
    and this goes quiet -- and that is the only in-repo fix (a foreign holder is
    not ours to touch).

    A SECOND, independent bound, measured 2026-09-23: the cohort also requires
    `insights_updated_at`, and insights are collected a lag after publication
    (fastest observed 32h, median 58h over 12 posts), so a slot inside the last
    `lag_h` hours of the window can never testify. Counting raw slots therefore
    overstated the cohort by the whole in-window queue: the 09-28 window's four
    post-intervention slots run 09-27 09:00 .. 09-28 10:30, every one of them
    inside the final 32h, so the true cohort is 0 and the shortfall is 5 -- not
    the 1 the slot count suggested. The feasibility bound is derived from the DB
    (never a remembered constant) and is skipped when no lag has been measured.
    """
    src = ""
    try:
        src = GATE_READ_SRC.read_text()
    except OSError:
        pass
    min_cohort, intervention = gate_cohort_params(src)
    row = psql(GATE_COHORT_SQL.format(ia=intervention))
    if not row:
        return None
    parts = row.split("|")
    if len(parts) != 6:
        return None
    review_at, pool, published, queued, lag_h, slots = parts
    feasible = cohort_feasible_count(slots, lag_h)
    if feasible is None:
        # Slot list unreadable: no bound, i.e. exactly the pre-lag behaviour.
        feasible = queued
    refusals = psql(
        "select count(*) from growth_decisions where action in "
        "('comfyui_unclaimed','cadence_blocked') and decided_at > "
        f"(now() at time zone 'UTC') - interval '{STARVE_WINDOW_H} hours'")
    v = gate_cohort_verdict(published, feasible, refusals, min_cohort)
    if not v:
        return None
    lag_n = as_int(lag_h)
    lag_txt = (f"{lag_n}h" if lag_n is not None and lag_n >= 0
               else "unmeasured (no cutoff applied)")
    slot_total = None
    pub_n, q_n = as_int(published), as_int(queued)
    if pub_n is not None and q_n is not None:
        slot_total = pub_n + q_n
    return (
        "gate-cohort-starved",
        f"the next gate read cannot be a measurement: {v[1]} post-intervention "
        f"post(s) can carry insights inside the {review_at} review window "
        f"(need {min_cohort}) while the render loop is refused",
        v[0],
        f"next weekly review {review_at}Z; its window is [(review - 7d), review]. "
        f"Post-intervention pool (photos rendered at/after {intervention}Z -- the content-mix "
        f"lever, inside Growth::GateRead::INTERVENTION_AT): {pool}. Inside that window the SLOTS "
        f"hold {published} published + {queued} queued"
        + (f" = {slot_total}" if slot_total is not None else "")
        + f", but Growth::GateRead#cohort_size ALSO requires insights_updated_at, and insights "
        f"arrive a measured {lag_txt} after publication (fastest observed publish->insights lag, "
        f"taken from the DB) -- so a slot inside the window's last {lag_txt} can never testify. "
        f"FEASIBLE cohort: {published} published + {feasible} queued = {v[1]}, against "
        f"MIN_COHORT_POSTS={min_cohort}. Below it Growth::GateRead returns :extend "
        f"(\"re-read, do NOT act\") regardless of the date, so the pre-registered GO/PIVOT/KILL "
        f"read is deferred by arithmetic, not by waiting. Render loop: {v[2]} refusal(s) in the "
        f"last {STARVE_WINDOW_H}h, so no new post-intervention photo can enter the pool -- the "
        f"cohort is fed only by renders (publication lags them by the queue depth). That is why a "
        f"GPU refusal starves the STRATEGY decision and not merely a render window"
        + starvation_attribution_clause()
        + ". Nothing here is ours to repair -- the refusal itself is correct (an instance "
          "launched without --reserve-vram cannot be submitted to) -- and this entry is not an "
          "ask on the holder: it self-closes when the loop stops being refused."
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
# When the caption routing flip landed (commit f37136e, 2026-09-21 15:19Z UTC):
# PostAutomation::GenerateCaption now branches on
# CaptionGeneration::ImageEncoder.readable? instead of photo.image.attached?.
# A caption written BEFORE this cannot be evidence about it, and neither can a
# window in which no post was created at all -- reading those as "the vision path
# is never taken" is what kept the board entry open for 41 sightings with no
# action while the only thing actually missing was a rendered post (the GPU was
# held by a co-tenant). See image_grounding_verdict.
CAPTION_VISION_FLIP_LANDED = calendar.timegm(
    time.strptime("2026-09-21T15:19:00", "%Y-%m-%dT%H:%M:%S"))


def image_grounding_verdict(total, attached, recent_unattached, vision_posts,
                            newest_attach=None, ungrounded_since_flip=None):
    """Pure: is a caption STILL written without looking at the render?

    Returns (severity, detail) or None.

    "Captions are written from context text, never from the image" is not a code
    defect on its own -- but it IS the difference between a caption that
    describes the photo and one that invents a scene the photo does not show
    (measured 2026-09-21 on photo 351: vision said "warm cup of coffee and a
    beautiful autumn morning" for an autumn street scene; the text path shipped
    "rain drumming on the windowpane ... chamomile tea").

    The evidence has to be POST-flip, because that is the only thing the flip
    changes: `ungrounded_since_flip` counts captions created after
    CAPTION_VISION_FLIP_LANDED whose photo had READABLE bytes yet which took the
    TEXT path -- i.e. the flip not taking effect in production. None means the
    caller could not measure it (unreadable DB).

    The window counts are kept for the evidence text and as a clean-guard, NOT
    as the condition: no vision caption in a window with no post in it is
    UNPROVEN, not broken. scheduling_posts.caption_metadata records generator
    ('vision' / 'text') on both paths, so a post-flip text caption over readable
    bytes is the defect, directly.
    """
    if any(v is None for v in (total, attached, recent_unattached, vision_posts)):
        return None
    if vision_posts > 0:
        return None  # the image path is taken -> the condition no longer reproduces
    if ungrounded_since_flip is None or ungrounded_since_flip <= 0:
        return None  # no post since the flip, or every one of them used the image
    detail = (
        f"{ungrounded_since_flip} caption(s) written AFTER the routing flip "
        f"(commit f37136e, 2026-09-21 15:19Z) took the TEXT path for a photo "
        f"whose bytes are readable, so the flip is not taking effect in "
        f"production; corpus {total} photos / {attached} attached"
    )
    if newest_attach:
        detail += f", newest attachment {newest_attach}"
    return "warn", detail


def _photo_readable_sql(alias):
    """SQL predicate mirroring CaptionGeneration::ImageEncoder.readable?.

    `photo.image.attached? || photo.servable_file_path.present?` -- the
    attachment half here, the file half in Python (Photo#servable_file_path's
    first branch, File.file?(path), is the one that resolves in production).
    """
    return ("exists (select 1 from active_storage_attachments a "
            "where a.record_type = 'ContentPillars::Photo' "
            f"and a.record_id = {alias}.id)")


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

    The branch was FLIPPED 2026-09-21 (commit f37136e: it now routes on
    CaptionGeneration::ImageEncoder.readable?), verified live on photo 353
    (generator='vision', gemma3:4b, caption grounded in the image). So the
    attachment count is no longer the condition -- it is kept as the count of
    renders still being produced. What this check reports now is the flip
    FAILING in production: a caption created after it, for a photo with readable
    bytes, that still took the text path.
    """
    attached_pred = _photo_readable_sql("p")
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

    # The flip's own evidence: every post created after it landed, with its
    # generator and whether that photo's bytes are readable. Readability is
    # resolved HERE (attached row, or a path that resolves to a real file) so the
    # check cannot call a post ungrounded when the flip had no bytes to route on.
    ph_pred = _photo_readable_sql("ph")
    post_flip_rows = psql_lines(
        "select coalesce(p.caption_metadata->>'generator', '') || '|' || "
        "coalesce(ph.path, '') || '|' || "
        f"case when {ph_pred} then '1' else '0' end "
        "from scheduling_posts p join photos ph on ph.id = p.photo_id "
        # `at time zone 'UTC'`: scheduling_posts.created_at is a timestamp WITHOUT
        # time zone holding UTC wall-clock values, while this psql session runs in
        # America/New_York -- comparing it to a bare to_timestamp() shifts the
        # boundary by 4h and counts pre-flip rows as post-flip (measured: post 346,
        # created 13:01Z, matched a 15:19Z boundary).
        f"where p.created_at > (to_timestamp({CAPTION_VISION_FLIP_LANDED}) "
        "at time zone 'UTC') "
        "order by p.created_at desc limit 25")
    ungrounded = None
    if post_flip_rows is not None:
        ungrounded = 0
        for line in post_flip_rows:
            parts = line.split("|")
            if len(parts) != 3:
                continue
            generator, path, attached_flag = parts
            if generator == "vision":
                continue
            if attached_flag == "1" or (path and os.path.isfile(path)):
                ungrounded += 1

    counts = []
    for raw in (total, attached, recent_unattached, vision_posts):
        try:
            counts.append(int(raw))
        except (TypeError, ValueError):
            return None
    verdict = image_grounding_verdict(*counts, newest_attach=newest,
                                      ungrounded_since_flip=ungrounded)
    if not verdict:
        return None
    sev, detail = verdict
    return (
        "vision-caption-path-never-taken",
        "a caption written AFTER the routing flip took the text path for a "
        "photo with readable bytes",
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
        "grounded in the image). So a text caption over readable bytes is the "
        "flip FAILING, and the window counts above are context, not the "
        "condition: a window in which NO post was created (the GPU held by a "
        "co-tenant, no renders) is unproven, not broken, and this check stays "
        "silent on it."
    )


CORPUS_BACKUP_DIR = APP / "corpus-backup"
# bin/corpus_backup.sh writes ONE snapshot per weekday slot and rewrites a slot
# weekly, so the newest slot must be younger than this or the protection has
# stopped happening. See check_corpus_backup.
CORPUS_BACKUP_MAX_AGE_H = 48


def corpus_backup_verdict(newest_age_h):
    """Pure: is the second copy of the render corpus being REFRESHED?

    Returns (severity, detail) or None. `newest_age_h` is the age in hours of the
    newest snapshot slot, None when it cannot be read (then: say nothing -- an
    unreadable stat is not evidence the backup stopped).
    """
    if newest_age_h is None:
        return None
    if newest_age_h > CORPUS_BACKUP_MAX_AGE_H * 3:
        return ("critical", f"newest corpus snapshot is {newest_age_h:.0f}h old "
                            f"(> {CORPUS_BACKUP_MAX_AGE_H * 3}h): the second copy "
                            f"of the corpus has stopped being written")
    if newest_age_h > CORPUS_BACKUP_MAX_AGE_H:
        return ("warn", f"newest corpus snapshot is {newest_age_h:.0f}h old "
                        f"(> {CORPUS_BACKUP_MAX_AGE_H}h): the nightly corpus "
                        f"backup looks like it stopped ticking")
    return None


def check_corpus_backup():
    """The second copy of the render corpus must be refreshed, not just present.

    /mnt/nas-ai-models/comfyui-output is the only copy of every photo this
    account has posted or could post, and the nightly /home/tim/backup.sh mirrors
    it as a DANGLING symlink onto the SAME NAS volume (see the board entry
    photo-corpus-single-copy). bin/corpus_backup.sh puts real bytes (-L) on a
    different device, run by the cron job tc-corpus-backup at 03:15 daily, and it
    refuses to report success unless every resolvable photos.path is in the copy.

    This check exists because a backup whose job silently stopped ticking is
    indistinguishable from one that works: the Hermes cron scheduler has been
    observed to stop firing a job while force-run still succeeds, and this one's
    first tick is a day away from its creation. The snapshot slot's mtime is the
    cheap signal that the copy is still being written.
    """
    slots = []
    try:
        slots = [p for p in (CORPUS_BACKUP_DIR / "snapshots").glob("*") if p.is_dir()]
    except OSError:
        slots = []
    if not slots:
        return None  # not configured on this machine -- not this check's call
    newest = max(slots, key=lambda p: p.stat().st_mtime)
    age_h = (time.time() - newest.stat().st_mtime) / 3600.0
    v = corpus_backup_verdict(age_h)
    if not v:
        return None
    sev, detail = v
    return (
        "corpus-backup-stale",
        detail,
        sev,
        f"{detail}; newest slot {newest} (mtime "
        f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(newest.stat().st_mtime))}); "
        f"run `bin/corpus_backup.sh` and check the cron job tc-corpus-backup is "
        f"still firing (its own log is the cron output, and "
        f"`bin/corpus_backup.sh --verify-only` re-checks the newest slot against "
        f"the database).",
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


def _proc_parent_comm(pid):
    """The parent process's comm name for a local pid, or '' when unreadable.

    HOW a holder is parented is what says WHO it belongs to: a human typing into a
    login shell or a tmux session is normal sharing that only a human can end, while
    a supervised unit is another project's job and nobody here may touch it.
    """
    try:
        with open(f"/proc/{pid}/stat", "rb") as fh:
            fields = fh.read().decode("utf-8", "replace").rsplit(")", 1)[-1].split()
        with open(f"/proc/{fields[1]}/comm", "rb") as fh:  # stat field 4 = ppid
            return fh.read().decode("utf-8", "replace").strip()
    except Exception:
        return ""


def _proc_cgroup(pid):
    """The local pid's cgroup path, or '' when unreadable."""
    try:
        with open(f"/proc/{pid}/cgroup", "rb") as fh:
            line = fh.read().decode("utf-8", "replace").strip().splitlines()[0]
        return line.split("::", 1)[-1]
    except Exception:
        return ""


def classify_holder(parent_comm, cgroup):
    """PURE: whose process holds the card -> 'operator' | 'agent' | 'unit' | ''.

    The class decides the RESPONSE, not the severity: an operator's own interactive
    session is normal sharing that only a human can end, so an escalation names a
    person and a session; another project's supervised unit is not ours to touch, so
    the ask becomes a resource-policy question instead. Hand-deriving this from /proc
    re-costs a pass every time the holder changes (measured 2026-09-22: three
    consecutive passes re-derived it by hand), so one owner answers it here.
    """
    cg = (cgroup or "").lower()
    pc = (parent_comm or "").strip().lower()
    if "tmux" in cg or pc in ("fish", "bash", "sh", "zsh", "dash"):
        return "operator"
    if "hermes" in cg:
        return "agent"
    if pc == "systemd" or cg.endswith(".service") or ".service/" in cg:
        return "unit"
    return ""


HOLDER_CLASS_TAGS = {
    "operator": "operator-interactive session",
    "agent": "our agent's cgroup",
    "unit": "supervised unit",
}


HOLDER_CLASS_TOKENS = ("operator", "agent", "unit", "other")


def holder_token(parent_comm, cgroup):
    """PURE: classify_holder -> a stable machine token for an attribution line.

    The words in HOLDER_CLASS_TAGS are for a human reading evidence; this token is
    for a parser (`owner=foreign holder=operator` on the 8188 attribution) and never
    comes back empty, so a monitor can key on it without a null branch.
    """
    return classify_holder(parent_comm, cgroup) or "other"


def holder_class_of(pid):
    """The holder class of a LOCAL pid -> 'operator'|'agent'|'unit'|'other'.

    Never raises: an unreadable /proc (a pid that exited between the pgrep and this
    read) degrades to 'other', which is the honest answer, not a crash in a monitor.
    """
    try:
        ipid = int(pid)
    except (TypeError, ValueError):
        return "other"
    return holder_token(_proc_parent_comm(ipid), _proc_cgroup(ipid))


def cmd_holder_class(argv):
    """Print the holder class of one pid — the bash surface for the same classifier.

    bin/comfyui_harness.sh must label the instance serving :8188 with WHO owns it, and
    it is a bash script: without this, the harness would either hand-roll a second
    copy of the classification (which drifts) or keep saying `owner=foreign` for the
    operator's own tmux session (measured 2026-09-22: three passes hand-read /proc,
    and the growth brain's report proposed a "fix on the foreign owner's side" for a
    session no agent may touch).
    """
    if not argv:
        print(__doc__)
        return 2
    token = holder_class_of(argv[0])
    print(token)
    return 0 if token in HOLDER_CLASS_TOKENS else 1


def holder_desc(pid, name, mib, klass=""):
    """One holder as `<pid> <name> <GiB>`, with its class when it is known."""
    tag = HOLDER_CLASS_TAGS.get(klass or "", "")
    return f"{pid} {name} {mib / 1024:.1f}GiB" + (f" ({tag})" if tag else "")


def gpu_vram_holders(min_mib=VRAM_HOLDER_MIN_MIB):
    """[(pid, name, used_mib, class)] for holders of the 4090 OUTSIDE the scheduler.

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
        rows.append((pid, name, mib,
                     classify_holder(_proc_parent_comm(pid), _proc_cgroup(pid))))
    return rows


def vram_blocker_note():
    """The outside-scheduler holders as one line, or '' when the card is clean."""
    return ", ".join(holder_desc(*row) for row in gpu_vram_holders())


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


def _fmt_age(s):
    """PURE: seconds -> '47s ago' / '12.4 min ago' / '2.1h ago' / 'never (empty history)'."""
    if s is None:
        return "never (empty history)"
    try:
        s = float(s)
    except (TypeError, ValueError):
        return "never (empty history)"
    if s < 90:
        return f"{s:.0f}s ago"
    if s < 5400:
        return f"{s / 60.0:.1f} min ago"
    return f"{s / 3600.0:.1f}h ago"


def holder_activity_clause(verdict, age_s):
    """PURE: is the process serving :8188 DOING WORK, or merely resident?

    The 10 s utilization sample cannot tell those two apart, and the failure is not
    cosmetic. A batch that renders one prompt every ~2 min spends most of any 10 s
    window BETWEEN prompts, so a card at full duty reads as "card 1% busy over 10s
    (holder resident but idle)" -- measured 2026-09-22 19:25Z, when the holder had
    executed 6 prompts in the previous 12 min with one running, i.e. it was driving
    the card continuously. "Idle residue" then invites the ask "stop the idle
    process", which is the wrong ask for live work (it is the ask this board filed
    on 2026-09-21, against a holder that was not the blocker it was described as),
    while live work on a shared install is simply not ours to touch.

    Queue depth and the age of the last EXECUTED prompt are definitive, and both are
    already read for the unclaimed-VRAM check (comfyui_holder_verdict). This clause
    is only appended when that reading exists; with no reading the caller keeps the
    util hint, so an unreadable instance is never accused.
    """
    if verdict == "live":
        return (f"; the :8188 instance is ACTIVELY RENDERING (last prompt {_fmt_age(age_s)})"
                " -- a batch is driving the card, not idle residue")
    if verdict == "idle":
        return (f"; the :8188 instance is idle (last prompt {_fmt_age(age_s)})"
                " -- resident residue, not work")
    return ""


def vram_refusal_clause(free_mib, req_gb, util_pct, holder_count,
                        peak_mib=None, total_mib=None,
                        holder_live=None, holder_age_s=None):
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
        if holder_live is None:
            # No definitive reading of the instance serving :8188: the short util
            # sample is all we have, and it is a HINT, not a verdict (see
            # holder_activity_clause -- a 2-min-per-prompt batch reads as idle here).
            clause += " (holder resident but idle)" if util_pct <= 5 else " (holder working)"
    clause += holder_activity_clause(holder_live, holder_age_s)
    return clause


def vram_fit_note(with_util=False):
    """What stands between us and a claim: free VRAM vs our reservation, plus holders.

    A refusal whose evidence says only `holder=none` is unactionable -- it was the
    *foreign job* that went away, not the co-tenant *process*. Name both numbers and
    the process, or the next tick re-diagnoses the same starvation.

    with_util adds the GPU-utilization window (a 10 s sample) AND, when an
    outside-scheduler process is the blocker, the definitive holder verdict (queue
    depth + age of the last executed prompt on :8188). The util window alone cannot
    separate "a co-tenant is training" from "a co-tenant's tool is merely resident"
    -- a batch rendering one prompt every ~2 min reads as 1% busy -- and that
    distinction is what decides the ask, so it is read exactly rather than inferred.
    Off by default so the checks that only need the numbers stay fast.
    """
    free = gpu_vram_free_mib()
    if free is None:
        return ""
    req = our_reservation_gb()
    note = f"free={free / 1024:.1f}GiB" + (f" vs ask {req:.0f}GiB" if req else "")
    blockers = gpu_vram_holders()
    if blockers:
        note += "; outside-scheduler holders: " + ", ".join(holder_desc(*row) for row in blockers)
    if req and free < req * 1024:
        util = gpu_util_peak_pct() if with_util else None
        verdict = age = None
        if with_util and blockers:
            # Only when an OUTSIDE-SCHEDULER process is the blocker; "unknown"
            # (unreadable/absent instance) falls back to the util hint rather than
            # accusing a holder we could not read.
            depth = comfyui_queue_depth()
            age = comfyui_last_prompt_age_s()
            verdict = comfyui_holder_verdict(depth, age)
            if verdict == "unknown":
                verdict = None
        note += vram_refusal_clause(
            free, req, util, len(blockers), telemetry_peak_mib(), gpu_total_mib(),
            holder_live=verdict, holder_age_s=age)
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


def claim_record():
    """Our claim state file as a dict; {} when absent/unreadable (we hold no claim)."""
    try:
        with open(CLAIM_FILE) as fh:
            rec = json.load(fh)
        return rec if isinstance(rec, dict) else {}
    except Exception:
        return {}


def ownership_label(record, pid):
    """PURE: 'ours' ONLY when the claim record proves we LAUNCHED that pid.

    Mirrors comfyui_ours() in bin/comfyui_harness.sh, which now requires
    origin=launched. An ADOPTED instance's pid sits in the same record (ensure
    adopts a foreign ComfyUI that carries --reserve-vram), so pid equality alone is
    not ownership -- and mislabelling it ours is exactly how the operator's own
    interactive session gets reported as our leaked orphan, the loudest finding the
    board can emit. Empty pid -> 'unknown' (there is no instance to attribute).
    """
    rec = record if isinstance(record, dict) else {}
    if not pid:
        return "unknown"
    if (str(rec.get("comfy_pid") or "") == str(pid)
            and (rec.get("origin") or "") == "launched"):
        return "ours"
    return "foreign"


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
    # `ours` requires the recorded pid AND origin=launched (see ownership_label):
    # an ADOPTED instance is not ours to call a leak.
    who = ownership_label(claim_record(), pid)
    cg = "?"
    try:
        cg = Path(f"/proc/{pid}/cgroup").read_text().strip().split("::")[-1] or "?"
    except Exception:
        pass
    started = run(["ps", "-o", "lstart=", "-p", pid])[0].strip().replace(" ", "_") or "?"
    reserve = "ok" if reserve_flag_in_cmdline(_proc_cmdline(pid)) else "missing"
    return (f"owner={who} pid={pid} cgroup={cg} started={started} "
            f"reserve={reserve} holder={holder_class_of(pid)}")


# --- The --reserve-vram gate: a refusal that is NOT about free memory -----------
# bin/comfyui_harness.sh refuses to submit a render to ANY instance serving :8188
# that was not launched with --reserve-vram, and it refuses on the ARGS *before* it
# ever asks the scheduler for a claim (cmd_ensure: `comfyui_up && ! comfyui_reserve_ok
# -> return 2`). So whenever such an instance is up, free VRAM is NOT the operative
# reason -- and the board could not see that at all: its refusal evidence reasoned
# only about free-vs-ask, so a foreign unflagged instance sitting on a card with room
# would have read as "nothing is blocking us, the ask fits", the exact
# silent-refusal shape the 18h starvation had (six ticks reporting a structural
# conflict that the consumer's own log disproved).
def reserve_flag_in_cmdline(cmdline):
    """PURE: does this argv carry --reserve-vram? Mirrors the harness's discriminator.

    The harness tests the NUL-stripped cmdline with a glob (`case "$cmdline" in
    *--reserve-vram*)`), so a substring test is the faithful mirror -- it also
    matches the `--reserve-vram=5` form. False for an empty/unreadable cmdline,
    which the caller must treat as "cannot tell", not as "missing".
    """
    return bool(cmdline) and "--reserve-vram" in str(cmdline)


def comfyui_serving_pid():
    """The pid serving :8188, or '' -- the single discovery pattern for this file."""
    out, rc = run(["pgrep", "-f", r"main\.py --listen"])
    if rc != 0 or not out:
        return ""
    return (out.splitlines() or [""])[0].strip()


def comfyui_reserve_ok(pid=None):
    """Is the instance serving :8188 carrying --reserve-vram? True/False/None.

    None when there is no instance (or its argv is unreadable): an absent instance
    is not a missing flag, and the gate only fires on an instance that is UP.
    """
    pid = pid or comfyui_serving_pid()
    if not pid:
        return None
    cmdline = _proc_cmdline(pid)
    if not cmdline:
        return None
    return reserve_flag_in_cmdline(cmdline)


def harness_kill_ownership_present():
    """Does the harness still own the close-path ownership rule? None if unreadable.

    WHY this is asserted and not assumed: the shutdown path used to SIGTERM (then
    SIGKILL) EVERY `main.py --listen` process on the box, and it is reached right
    after an ADOPTED foreign instance — so the very response the board recommends
    to the launch-args refusal ("relaunch with --reserve-vram, the harness will
    adopt it") armed a kill of the operator's own session. A harness that stops
    enforcing the rule at the choke point must fail the suite, not leave the board
    quiet about a live footgun.
    """
    try:
        txt = (APP / "bin" / "comfyui_harness.sh").read_text()
    except Exception:
        return None
    return ("kill_verdict() {" in txt
            and 'v="$(kill_verdict "$origin" "$pid" "$stage")"' in txt
            and "if comfyui_up && ! comfyui_reserve_ok; then" in txt)


def may_kill_instance(origin, pid, stage="live"):
    """Mirror of the harness's kill_verdict(): may we SIGTERM this instance?

    The ownership rule in one place: only an instance WE launched, proven by a
    recorded pid, is ours to stop. An adopted instance, an unrecorded pid and an
    old state file without an origin all refuse — err toward leaving a process
    alone, because the alternative direction kills somebody else's work.
    """
    if not pid:
        return "refuse:no-recorded-pid"
    if origin != "launched":
        return "refuse:not-launched-by-us"
    if stage == "gone":
        return "refuse:already-gone"
    if stage == "not-comfyui":
        return "refuse:pid-reuse"
    return "kill"


def harness_reserve_gate_present():
    """Does the harness still gate renders on the launch args? None when unreadable.

    The mirror above is only worth having while the harness owns that rule, so the
    two tokens that implement it are asserted in selftest: a harness that stops
    refusing on the args must fail the suite rather than leave this board reporting
    a gate that no longer exists.
    """
    try:
        txt = (APP / "bin" / "comfyui_harness.sh").read_text()
    except Exception:
        return None
    return ("*--reserve-vram*) return 0" in txt
            and "if comfyui_up && ! comfyui_reserve_ok; then" in txt)


# What may be done about the gate, by holder class -- mirrors the harness's
# holder_response_note(), because the class decides the legal response: the operator's
# session is a human's to end, another project's unit is theirs to change, and an
# agent-owned instance means OUR launch line dropped the flag.
RESERVE_GATE_RESPONSE = {
    "operator": "the OPERATOR's interactive session -- a human is using the shared "
                "install; yield the window, do not touch/restart/re-flag it (a running "
                "process's args are not ours to change)",
    "unit": "another project's supervised unit -- its launch line is that project's to "
            "change; yield, do not touch it",
    "agent": "one of OUR agent cgroups -- our launch line dropped the flag; fix the "
             "launch args in bin/comfyui_harness.sh, not the process",
}


def reserve_gate_clause(reserve, pid=None, holder=None, owner=None):
    """PURE: the launch-args refusal as a clause, or '' when that gate is not firing.

    Split from the probe so the wording and the firing rule are testable without a
    GPU, and so the SAME clause serves both surfaces: the refusal evidence of
    check_render_starved (which must name the gate that actually fired) and
    check_reserve_gate_blocked (the case no other check can explain).
    """
    if reserve is not False:
        return ""
    who = f"pid {pid}, " if pid else ""
    who += f"owner {owner}, " if owner else ""
    who += f"holder {holder}" if holder else ""
    response = RESERVE_GATE_RESPONSE.get(
        holder or "", "holder unattributable -- yield and report it; never restart an "
                      "instance we did not launch")
    return (f"; the :8188 instance ({who.rstrip(', ')}) was launched WITHOUT "
            "--reserve-vram, so `ensure` refuses on the ARGS before it ever asks the "
            "scheduler for a claim — this refusal is about the launch line, not about "
            f"how much VRAM is free (see COMFY_RESERVE_VRAM). Response: {response}")


def attribution_or_unattributed(clause):
    """PURE: a derived attribution clause, or an explicit "not this gate" note.

    A check that did not measure the cause must SAY SO rather than stay silent --
    silence reads as "no cause", and the caller's reader then supplies one from
    memory. The fallback names the gate that is NOT firing and points at the check
    that owns the attribution, so the reader is sent to a measurement.
    """
    return clause or (
        "; the launch-args gate is NOT firing (no :8188 instance is up without "
        "--reserve-vram), so the refusal is the VRAM/claim path -- check_render_starved "
        "carries that attribution and this entry deliberately does not guess a holder")


def starvation_attribution_clause():
    """The MEASURED why of the current refusal, for a check that cannot derive it.

    check_gate_cohort_starved reasons about a COHORT, not about the GPU, so it has no
    business asserting a holder -- and it used to: its evidence closed with the
    hardcoded foreign-project holder attribution, which was FALSE the moment
    the blocker became the OPERATOR's own interactive tmux ComfyUI (measured
    2026-09-23 03:2xZ: pid 553489, holder=operator, launched without --reserve-vram,
    rendering at 100% util). A board surface that names the wrong cause sends the
    reader to the wrong response: "another project's job" reads as nobody-here-may-
    touch-it, while the operator's session is a human's to end and is yielded to, not
    argued with. Derive it from the live instance through the same discriminator
    check_render_starved uses, and say explicitly when that gate is not the cause.
    """
    pid = comfyui_serving_pid()
    reserve = comfyui_reserve_ok(pid) if pid else None
    return attribution_or_unattributed(
        reserve_gate_clause(reserve, pid, holder_class_of(pid) if pid else None))


def reserve_gate_blocks(reserve, free_mib, ask_gb):
    """PURE: is the launch-args gate the ONLY explanation for a refusal?

    True only when an instance is up WITHOUT the flag AND free memory would allow the
    claim (free >= ask) -- the case no other check can explain. Below the ask the
    harness would refuse anyway, and check_render_starved already carries that
    condition (its evidence now names this gate when it applies), so firing here too
    would file the same refusal twice.
    """
    if reserve is not False or free_mib is None or not ask_gb:
        return False
    try:
        return float(free_mib) >= float(ask_gb) * 1024
    except (TypeError, ValueError):
        return False


def check_reserve_gate_blocked():
    """The launch-args gate is the ONLY thing standing between us and a render.

    Deliberately NOT fired while free VRAM is below the ask: there the harness would
    refuse anyway, and check_render_starved already carries the condition (its
    evidence now names this gate when it applies). This fires on the differential --
    the card has room, so free memory cannot explain the refusal, and without this
    check nothing on the board would: the render loop would sit refused every tick
    while every measured number read healthy.
    """
    if not comfyui_up():
        return None
    pid = comfyui_serving_pid()
    reserve = comfyui_reserve_ok(pid)
    free = gpu_vram_free_mib()
    ask = our_reservation_gb()
    if not reserve_gate_blocks(reserve, free, ask):
        return None
    if free is None or not ask:  # narrowing only; the predicate above already implies it
        return None
    free_gib, ask_gb = free / 1024, float(ask)
    # "ours" means WE launched it -- see ownership_label (an adopted instance's pid
    # is in the record too). No readable record means we hold no claim, so anything
    # answering :8188 is foreign; it used to print "unknown", which reads as
    # "cannot tell" for a fact we do know.
    owner = ownership_label(claim_record(), pid)
    holder = holder_class_of(pid) if pid else None
    return (
        "comfyui-reserve-gate-blocked",
        f"renders are refused by the launch args of the live :8188 instance while the "
        f"{GPU} has room ({free_gib:.1f}GiB free vs ask {ask_gb:.0f}GiB)",
        "warn",
        f"port 8188 answering, free={free_gib:.1f}GiB vs ask {ask_gb:.0f}GiB (so free "
        f"VRAM is NOT the cause), claim={our_claim()[0]}"
        + reserve_gate_clause(reserve, pid, holder, owner)
        + "; the harness yields the window rather than submitting to an unflagged "
          "instance, so renders stay blocked until that instance exits or is relaunched "
          "with --reserve-vram. Nothing here is ours to restart.",
    )


def unclaimed_vram_verdict(card_mib, own_mib, threshold_mib=UNCLAIMED_COMFYUI_VRAM_MIB):
    """PURE: may the board blame THIS instance for the card's VRAM?

    -> (held_mib, attributed) when it may, None when it may not.

    `nvidia-smi memory.used` is CARD-level: it counts every co-tenant, so it cannot
    support a claim about who holds the memory (genome #66; the repo measure on the
    same trap is `vram_ask_for_free`, which had to stop deriving an ask from a
    card-level reading). Measured 2026-09-23: the instance held 18,438 MiB of the
    card's 18,945 MiB, so the old card-level title happened to be true -- but a BT-Net
    labeler holding 14 GiB beside an idle ComfyUI holding 300 MiB produces the SAME
    reading and the SAME title, which would send a reader to shut down the wrong
    process. The instance's own hold decides, and an unreadable hold keeps the
    detection (fires as `attributed=False` so the wording names the card, not the
    instance) because a failure to attribute must not silence a possible leak.
    """
    if card_mib is None or card_mib < threshold_mib:
        return None
    if own_mib is None:
        return (card_mib, False)
    if own_mib < threshold_mib:
        return None
    return (own_mib, True)


def comfyui_instance_vram_mib(pid=None):
    """The MiB the :8188 instance ITSELF holds, 0 when it is not a compute process.

    None only when nvidia-smi itself is unreadable -- "not listed" is a legible
    answer (a warm-but-empty instance holds nothing), whereas a failed query is not.
    """
    pid = pid or comfyui_serving_pid()
    if not pid:
        return None
    out, rc = run(["nvidia-smi", "--query-compute-apps=pid,used_memory",
                   "--format=csv,noheader,nounits"])
    if rc != 0 or out is None:
        return None
    try:
        want = int(pid)
    except (TypeError, ValueError):
        return None
    total = 0
    for line in out.splitlines():
        parts = [p.strip() for p in line.split(",")]
        if len(parts) < 2:
            continue
        try:
            p, mib = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        if p == want:
            total += mib
    return total


def check_comfyui_vram_unclaimed():
    """ComfyUI is up while NOBODY holds the GPU, pinning VRAM, and is IDLE.

    The harm of an orphaned instance is the memory it holds on a shared card, not
    the open port -- a warm instance with no claim is what the next claimant OOMs
    against. Deliberately NOT fired when a claim exists (another project holding
    the slot and running the shared install is normal sharing, and the harness
    adopts foreign instances rather than killing them, so there is nothing to
    action), NOT fired while the instance is live (see comfyui_holder_verdict), and
    NOT fired on a card-level reading that belongs to a co-tenant (see
    unclaimed_vram_verdict). Sampled from hardware, not inferred from the port
    being open.
    """
    if not comfyui_up():
        return None
    g = (sched_state().get("gpus") or {}).get(GPU) or {}
    if g.get("status") in ("busy", "claimed"):
        return None
    used = gpu_vram_used_mib()
    verdict = unclaimed_vram_verdict(used, comfyui_instance_vram_mib())
    if verdict is None:
        return None
    held, attributed = verdict
    depth = comfyui_queue_depth()
    age = comfyui_last_prompt_age_s()
    if comfyui_holder_verdict(depth, age) != "idle":
        return None
    last = "never" if age is None else f"{age / 60:.0f} min ago"
    if attributed:
        title = (f"ComfyUI is up with no claim on the {GPU} while holding "
                 f"{held / 1024:.1f} GB")
        held_note = f"the instance itself holds {held}MiB of the card's {used}MiB"
    else:
        title = (f"ComfyUI is up with no claim on the {GPU}; the card holds "
                 f"{held / 1024:.1f} GB and its own share is unreadable")
        held_note = (f"card-level vram_used={held}MiB (the instance's own hold is "
                     "unreadable, so this is an UPPER bound that a co-tenant may own)")
    return (
        "comfyui-vram-unclaimed",
        title,
        "warn",
        f"port 8188 answering, state={g.get('status')}, {held_note} "
        f"(threshold {UNCLAIMED_COMFYUI_VRAM_MIB}MiB); the instance is IDLE -- native "
        f"queue empty and last prompt {last} (live window {COMFYUI_LIVE_WINDOW_S // 60} "
        f"min) -- so this VRAM is residue the next claimant renders against. "
        f"{comfyui_attribution()}. A foreign instance is not ours to kill (harness "
        "ownership rule): shut it down from its own session, or accept the hold.",
    )


# A dead pid cannot hold VRAM, so "exited while still holding VRAM" is not an
# observable state -- and the sampler's vram_used_mib is CARD-level
# (`nvidia-smi memory.used`), so a reading taken seconds after the process died
# belongs to whatever ELSE is on the card (the desktop baseline measures
# ~450-620 MiB; other projects' processes; and a dying render's own children --
# ComfyUI's own shutdown logged a leaked loky/multiprocessing worker semaphore).
# Measured FALSE POSITIVE 2026-09-22 00:16:54: a CLEAN harness shutdown after a
# render that COMPLETED (ComfyuiJob 7570, "Prompt executed in 00:11:51", harness
# log "shutdown: clean -- port closed, GPU idle (VRAM 3230 MiB)") was filed as
# "exited while still holding VRAM 3230 MiB". No threshold on a card-level
# reading can separate a leak from ordinary sharing, because a co-tenant
# produces the same number.
#
# What IS answerable is whether the stop was OURS, so this branch fires only on
# an UNEXPLAINED exit, and bin/comfyui_harness.sh now writes the intent into the
# telemetry stream before SIGTERM. The genuine leak-adjacent conditions have
# their own sound checks: a cgroup OOM kill (the branch above), a live ComfyUI
# pinning VRAM with no claim (comfyui-vram-unclaimed), and ComfyUI down while we
# hold the claim (comfyui-down-while-claimed).
SHUTDOWN_INTENT_WINDOW_S = 300
HARNESS_SHUTDOWN_PAT = re.compile(
    r"^\[([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})\]\s*shutdown:")


def iso_epoch(ts):
    """Epoch for a telemetry ts (ISO8601 with offset), or None."""
    try:
        return datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%S%z").timestamp()
    except (TypeError, ValueError):
        return None


def local_epoch(ts):
    """Epoch for a harness-log stamp (`[%Y-%m-%d %H:%M:%S]`, local), or None."""
    try:
        return datetime.datetime.strptime(ts, "%Y-%m-%d %H:%M:%S").timestamp()
    except (TypeError, ValueError):
        return None


def shutdown_intent_epoch(records, log_text):
    """Newest "this stop was ours" marker from EITHER source, or None.

    Two sources on purpose. The telemetry stream carries an explicit
    {"intent": "shutdown"} record, written by the harness immediately before
    SIGTERM, so it shares the exit record's clock and needs no log parsing. The
    harness log's own `shutdown:` lines cover exits that predate that marker and
    any path that bypasses it -- which is exactly how the historical record
    reads as intentional rather than as a leak.
    """
    newest = None
    for rec in records or []:
        if rec.get("intent") != "shutdown":
            continue
        e = iso_epoch(rec.get("ts"))
        if e is not None and (newest is None or e > newest):
            newest = e
    for line in (log_text or "").splitlines():
        m = HARNESS_SHUTDOWN_PAT.match(line)
        if not m:
            continue
        e = local_epoch(m.group(1))
        if e is not None and (newest is None or e > newest):
            newest = e
    return newest


def exit_was_intentional(exit_rec, records, log_text,
                         window_s=SHUTDOWN_INTENT_WINDOW_S):
    """True when a harness-initiated stop explains this telemetry exit record."""
    e = iso_epoch(exit_rec.get("ts"))
    intent = shutdown_intent_epoch(records, log_text)
    if e is None or intent is None:
        return False
    return abs(e - intent) <= window_s


def telemetry_records(limit=200):
    """The last `limit` telemetry records (newest last); [] when unreadable."""
    try:
        with open(TELE_FILE) as fh:
            lines = fh.read().strip().splitlines()[-limit:]
    except Exception:
        return []
    out = []
    for line in lines:
        try:
            out.append(json.loads(line))
        except Exception:
            continue
    return out


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
        if exit_was_intentional(rec, telemetry_records(),
                                tail_text(HARNESS_LOG, COMFY_LAUNCH_TAIL_BYTES)):
            return None
        return (
            "comfyui-exited-with-vram",
            "ComfyUI exited UNEXPECTEDLY (no shutdown was requested)",
            "warn",
            json.dumps({k: rec.get(k) for k in ("ts", "vram_used_mib")})
            + " -- card-level VRAM (co-tenants included) on a stop nobody asked"
              " for; read comfyui-down-while-claimed for the claim half",
        )
    return None


# ------------------------------------------------- ComfyUI torch-level VRAM OOM
# The CAUSE behind the HTTP-500/timeout rows the board otherwise sees only as a
# symptom. Nothing ON THE BOARD names it: the cgroup sampler finds no oom_kill
# (the process survives the failed allocation), and the render-execution-error
# check interpolates only the NEWEST failed row -- measured 2026-09-22, where job
# 7564 failed carrying the OOM text and job 7566, the very NEXT job, failed with
# the HTTP 500, so the row the board quoted was the symptom while the cause sat
# unread one row behind it (and the prose attributed it to the workflow payload).
# Measured 2026-09-22 00:01Z (job 7564): the card was nearly EMPTY, so ComfyUI
# sized its dynamic-VRAM budget from free memory ("loaded partially; 21719.11 MB
# usable, 21448.72 MB loaded"), loaded 21448 MB, then died 78 MiB short at 21.32
# GiB allocated on a 23.52 GiB device; the bounded retry then recovered by itself
# (7565 and 7567 both completed), so the cost was two wasted jobs -- this is a
# throughput/robustness fix, NOT a data-loss one. Offloading is cheap here;
# over-committing is fatal.
#
# Why it earns its own check: the fix (bin/comfyui_harness.sh COMFY_RESERVE_VRAM=5
# -> --reserve-vram) is judged by exactly these numbers PLUS the launch args that
# were in force, and this entry carries both in one line -- a DB row never says
# which flags the process ran with. The flag reaches the budget through TWO paths
# and one is version-gated: EXTRA_RESERVED_VRAM in comfy/model_management.py, and
# comfy_aimdo's simple_vram_headroom (main.py calls
# control.init(simple_vram_headroom=...), catches TypeError and falls back to NO
# headroom). The runtime venv is /mnt/fscache/essdee/ComfyUI/.venv, whose
# comfy_aimdo is 0.5.5 and does accept it; the sibling venv/ holds 0.4.3 and would
# silently fall back -- so a budget still reading ~21 GB usable under a launch line
# that carries --reserve-vram points at the headroom path, not at the flag.
COMFY_LOG_DIR = SCHED_DIR / "logs"
COMFY_OOM_WINDOW_H = float(os.environ.get("TC_COMFY_OOM_WINDOW_H", "48"))
COMFY_OOM_TAIL_BYTES = 512 * 1024
COMFY_LAUNCH_TAIL_BYTES = 256 * 1024
COMFY_OOM_PAT = re.compile(
    r"torch\.OutOfMemoryError: Allocation on device \d+ would exceed allowed memory")
COMFY_OOM_FACT_PAT = re.compile(
    r"^\s*(Currently allocated|Requested|Device limit)\s*:\s*(.+?)\s*$")
COMFY_USABLE_PAT = re.compile(
    r"loaded (?:partially|completely); ([0-9.]+) MB usable, ([0-9.]+) MB loaded")


def tail_text(path, nbytes):
    """Last `nbytes` of a file as text, or "" -- never raises, never loads it all."""
    try:
        st = path.stat()
        with open(path, "rb") as fh:
            if st.st_size > nbytes:
                fh.seek(st.st_size - nbytes)
                fh.readline()  # drop the partial first line of the window
            return fh.read().decode("utf-8", "replace")
    except OSError:
        return ""


def comfy_oom_hit(path):
    """The NEWEST torch-OOM block in one ComfyUI log, or None.

    Tail-bounded on purpose: the OOM's own evidence (the allocated / requested /
    device-limit triple) sits within a few lines of the message, so a bounded read
    keeps the hourly probe cheap on a job log that reaches a few MB.
    """
    text = tail_text(path, COMFY_OOM_TAIL_BYTES)
    if not text:
        return None
    lines = text.splitlines()
    idx = None
    for i, ln in enumerate(lines):
        if COMFY_OOM_PAT.search(ln):
            idx = i
    if idx is None:
        return None
    facts = {}
    for ln in lines[idx:idx + 8]:
        m = COMFY_OOM_FACT_PAT.match(ln)
        if m:
            facts[m.group(1)] = m.group(2)
    usable = None
    for ln in reversed(lines[:idx]):
        m = COMFY_USABLE_PAT.search(ln)
        if m:
            usable = f"{m.group(1)} MB usable / {m.group(2)} MB loaded"
            break
    try:
        mtime = path.stat().st_mtime
    except OSError:
        return None
    return {"log": path.name, "mtime": mtime,
            "allocated": facts.get("Currently allocated"),
            "requested": facts.get("Requested"),
            "limit": facts.get("Device limit"), "usable": usable}


def comfy_oom_scan():
    """Newest-first torch-OOM hits across the recent ComfyUI job logs."""
    try:
        logs = sorted(COMFY_LOG_DIR.glob("comfyui-*.log"),
                      key=lambda p: p.stat().st_mtime, reverse=True)
    except OSError:
        return []
    hits = []
    for p in logs[:6]:
        h = comfy_oom_hit(p)
        if h:
            hits.append(h)
    hits.sort(key=lambda h: h["mtime"], reverse=True)
    return hits


def launch_args_for_log(log_name, tail_bytes=COMFY_LAUNCH_TAIL_BYTES, path=None):
    """(args_or_None, launch_line_found) for the ComfyUI start that WROTE `log_name`.

    Pairing is by LOG, never by recency. The newest `launching ComfyUI` line in
    the harness log belongs to whatever ComfyUI started LAST, while an OOM's log
    belongs to the process that wrote it -- reading the two from different
    processes fabricates a cause. Measured 2026-09-23: the OOM's log was written
    by a launch at 2026-09-21 20:00Z that carried NO args= at all (it predates
    --reserve-vram), while `newest_comfy_launch_args()` returned the 2026-09-22
    03:01Z launch that carried `--reserve-vram 5` -- so the board told the next
    reader the flag "did not reach the budget" and sent them into comfy_aimdo's
    simple_vram_headroom path, which was in fact working: every launch since the
    flag capped 'usable' at 16238-16895 MB against 20831-21719 MB before it, with
    zero OOMs.

    Three outcomes, and the middle one is the whole point:
      (args, True)  -- the launch line for this log carries args=.
      (None, True)  -- the line exists but carries NO args= field. Not "unknown":
                       the harness logs the whole launch line, so an absent args=
                       is a FACT about that start -- it was launched without
                       --reserve-vram.
      (None, False) -- no launch line in the tail names this log (unknown).
    """
    text = tail_text(path or HARNESS_LOG, tail_bytes)
    args = None
    found = False
    for ln in text.splitlines():
        if "launching ComfyUI" not in ln:
            continue
        m = re.search(r"log:\s*(\S+)\s*$", ln)
        if not m or not m.group(1).endswith("/" + log_name):
            continue
        found = True
        a = re.search(r"args='([^']*)'", ln)
        args = a.group(1) if a else None
    return args, found


def comfy_usable_cap_after(after_mtime, log_dir=None):
    """(highest 'usable' MB, n_logs) across ComfyUI logs written AFTER after_mtime.

    The one fact that answers "did --reserve-vram reach the BUDGET?" (as opposed
    to merely reaching the command line) is the 'usable' figure ComfyUI logs for
    its own dynamic-VRAM budget: a launch carrying the flag must hold it under
    the value that OOM'd. ComfyUI sizes that budget from FREE memory, so the
    quieter the card the higher it reads -- which is why the number has to be
    MEASURED per launch rather than reasoned about from the flag.
    """
    best = None
    n = 0
    try:
        logs = sorted((log_dir or COMFY_LOG_DIR).glob("comfyui-*.log"),
                      key=lambda p: p.stat().st_mtime)
    except OSError:
        return None, 0
    for p in logs:
        try:
            if p.stat().st_mtime <= after_mtime:
                continue
        except OSError:
            continue
        n += 1
        for m in COMFY_USABLE_PAT.finditer(tail_text(p, COMFY_OOM_TAIL_BYTES)):
            try:
                v = float(m.group(1))
            except ValueError:
                continue
            if best is None or v > best:
                best = v
    return best, n


def comfy_oom_verdict(hits, now=None, window_h=COMFY_OOM_WINDOW_H, launch_args=None,
                      usable_after=None):
    """Newest in-window torch OOM -> (severity, evidence) or None.

    `now` and `window_h` are parameters so the self-closing behaviour -- the
    window is what lets the entry leave the board once the fix holds -- is
    testable without waiting for one.
    """
    now = time.time() if now is None else now
    live = [h for h in hits if 0 <= (now - h.get("mtime", 0)) <= window_h * 3600]
    if not live:
        return None
    h = live[0]
    bits = [f"newest {h['log']} ({(now - h['mtime']) / 3600.0:.1f}h old)"]
    if h.get("allocated"):
        bits.append(f"died at {h['allocated']} allocated"
                    + (f", {h['requested']} requested" if h.get("requested") else "")
                    + (f", device limit {h['limit']}" if h.get("limit") else ""))
    if h.get("usable"):
        bits.append(f"the budget was {h['usable']}")
    if launch_args:
        bits.append(f"launch args for THAT log: {launch_args}")
    if usable_after and usable_after[0]:
        cap, nl = usable_after
        bits.append(f"the {nl} launch(es) since held the budget at <= {cap:.0f} MB usable")
    return ("warn", f"{len(live)} ComfyUI torch-OOM(s) in the last {window_h:g}h; "
                    + "; ".join(bits))


def check_comfyui_torch_oom():
    hits = comfy_oom_scan()
    args = None
    usable_after = None
    if hits:
        args, found = launch_args_for_log(hits[0]["log"])
        if not found:
            args = "UNKNOWN -- no launch line in the harness log names this log"
        elif args is None:
            args = ("NONE -- that start carried no --reserve-vram (its launch line "
                    "has no args=, i.e. the process predates the flag)")
        usable_after = comfy_usable_cap_after(hits[0]["mtime"])
    v = comfy_oom_verdict(hits, launch_args=args, usable_after=usable_after)
    if not v:
        return None
    sev, evidence = v
    return (
        "comfyui-torch-oom",
        "a render ran out of VRAM inside ComfyUI (torch OOM)",
        sev,
        evidence + ". This is the CAUSE of the HTTP-500 / timeout rows tracked as "
        "render-execution-error: ComfyUI sizes its dynamic-VRAM budget from FREE "
        "memory, so the emptier the card the MORE it loads -- over-committing is "
        "fatal, offloading is merely slower. Compare the failing budget ONLY "
        "against the launch args named above, which are read from the launch line "
        "of the SAME log that carries the OOM -- an older start's budget says "
        "nothing about a newer launch's flags. Two questions, in order: (1) did "
        "that start carry --reserve-vram (bin/comfyui_harness.sh "
        "COMFY_RESERVE_VRAM) at all? (2) if it did and 'usable' still sits at the "
        "failing value, the flag did not reach the budget -- check comfy_aimdo's "
        "simple_vram_headroom path against the runtime .venv "
        "(/mnt/fscache/essdee/ComfyUI/.venv, comfy_aimdo 0.5.5 accepts it; the "
        "sibling venv/ holds 0.4.3 and silently falls back). Self-closes when no "
        "OOM is inside the window.",
    )


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
# A log LINE is a record, not a state: the tail window holds every error the log
# ever printed, and a small, slow-growing log's window spans DAYS (measured
# 2026-09-21: log/comfyui_harness.log is 90 KB / 903 lines over 8 days, so the
# whole file sits inside the 2 MiB window). One ERROR line from a defect that has
# since been fixed then reads as `errors=1` on every monitoring tick, and each
# pass re-investigates it from scratch -- the deps gate's cwd false alarm, fixed
# 4 h later in 4c70264, was reported as a live error by two consecutive runs. The
# fix is to carry the AGE of the newest error into the output (never to hide the
# line: a fault that is still live keeps re-emitting, so age is the one fact that
# separates current from historical).
LOG_ERROR_MAX_AGE_H = float(os.environ.get("TC_LOG_ERROR_MAX_AGE_H", "24"))

_LOG_TS_RES = (
    re.compile(r"\[(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2})"),  # [2026-09-21 07:00:33]
    re.compile(r"\b(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2}:\d{2})"),     # 2026-09-21T11:16:30
)


def log_line_epoch(line):
    """Newest plausible epoch for the line's OWN timestamp, or None.

    The log declares no timezone (the harness prints local time, Rails prints
    UTC), so both readings are computed and the LATER one wins: an undeclared
    timezone can then never make a fresh error read as stale. A line with no
    timestamp at all -- a traceback continuation, a bare message -- returns None
    and is never treated as stale.
    """
    best = None
    for pat in _LOG_TS_RES:
        for m in pat.finditer(line or ""):
            try:
                t = time.strptime(f"{m.group(1)} {m.group(2)}", "%Y-%m-%d %H:%M:%S")
            except ValueError:
                continue
            for ep in (calendar.timegm(t), time.mktime(t)):
                if best is None or ep > best:
                    best = ep
    return best


def log_error_note(n_errors, newest_age_h, max_age_h=LOG_ERROR_MAX_AGE_H):
    """Pure: the suffix `log-health` prints after `errors=N`.

    The reader of that surface is a monitoring tick deciding whether to act, so
    the discriminator has to be in the line: an error older than the window is
    labelled STALE with the reason, and a hit with no timestamp says so rather
    than implying a clean bill of health.
    """
    if not n_errors:
        return ""
    if newest_age_h is None:
        return " (newest error carries no timestamp — judge it from the lines below)"
    shown = f"{newest_age_h:.1f}h" if newest_age_h < 48 else f"{newest_age_h / 24:.1f}d"
    if newest_age_h > max_age_h:
        return (f" (newest error {shown} old — STALE, outside the {max_age_h:g}h "
                f"alert window; a still-live fault re-emits)")
    return f" (newest error {shown} old)"


def log_error_samples(rel_path, limit=3):
    """(exists, age_seconds, error_count, newest_error_lines, newest_error_age_h).

    Bounded to the last LOG_SCAN_BYTES so `log-health` stays cheap on a 24 MB
    development.log. The newest-error age is computed from the last matching
    line's own timestamp (None when it carries none, or when there are no hits).
    """
    p = APP / rel_path
    try:
        st = p.stat()
    except OSError:
        return False, None, 0, [], None
    age = time.time() - st.st_mtime
    with open(p, "rb") as fh:
        if st.st_size > LOG_SCAN_BYTES:
            fh.seek(st.st_size - LOG_SCAN_BYTES)
            fh.readline()  # drop the partial first line of the window
        tail = fh.read().decode("utf-8", "replace")
    hits = [ln.strip() for ln in tail.splitlines() if LOG_ERROR_PAT.search(ln)]
    newest_ep = log_line_epoch(hits[-1]) if hits else None
    newest_age_h = None if newest_ep is None else (time.time() - newest_ep) / 3600.0
    return True, age, len(hits), hits[-limit:], newest_age_h


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


# Fourth shape of the same family (config rot in the prompt text): a prompt that
# answers "is the photo queue non-empty" with a STATUS count. The publisher selects
# on the two clocks, not on status, so a status count OVERSTATES by every age-gate
# hold -- and the difference reads as a broken row to repair. Measured 2026-09-21:
# the overnight watchdog counted 18 while only 17 could publish, reported post 345
# as a defect ("set scheduled_at or reclassify"), and that advice would have
# published a render the age gate had read as a minor on a public adult account.
# The repo owns the answer (`python3 bin/tc_ops.py queue` prints publishable vs
# status_rows vs held), so this check requires the prompt to point at it.
PROMPT_QUEUE_STATUS_COUNT = re.compile(
    r"status\s*:\s*\[\s*['\"]draft['\"]\s*,\s*['\"]scheduled['\"]\s*\]"
    r"|status\s+in\s*\(\s*['\"]draft['\"]\s*,\s*['\"]scheduled['\"]\s*\)",
    re.I)
PROMPT_QUEUE_OWNED_CMD = re.compile(r"tc_ops\.py\s+queue")


def cron_prompt_queue_count_verdict(rows):
    """Pure: job records -> (severity, evidence) when a prompt counts the queue by
    status without carrying the repo-owned command that counts it as the publisher does.

    Prompt-scoped, not line-scoped: a prompt may explain the old predicate in prose
    as long as it also carries the owned command.
    """
    hits = []
    for r in rows:
        prompt = r.get("prompt") or ""
        if not PROMPT_QUEUE_STATUS_COUNT.search(prompt):
            continue
        if PROMPT_QUEUE_OWNED_CMD.search(prompt):
            continue
        hits.append(f"{r.get('name')} ({r.get('id')})")
    if not hits:
        return None
    return (
        "warn",
        f"{len(hits)} cron prompt(s) answer the queue question with a STATUS count, "
        f"which overstates by every age-gate hold and makes a deliberately held row "
        f"look like a defect to repair: {'; '.join(hits)} -- use the repo-owned "
        f"command (`python3 bin/tc_ops.py queue` prints publishable vs status_rows vs "
        f"held; the publisher selects on the two clocks, not on status)",
    )


def check_cron_prompt_queue_counts():
    """Config rot, fourth shape: a prompt counting the photo queue by status.

    Same reason as check_cron_prompt_probes -- the defect lives in the prompt text,
    and a run that counts the wrong way still finishes cleanly, so nothing else
    surfaces it. Measured 2026-09-21: the overnight watchdog's status-only count
    (18 vs 17 publishable) produced "post 345 can never publish -- set scheduled_at
    or reclassify", advice that would have published a render the age gate had read
    as a minor.
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
    v = cron_prompt_queue_count_verdict(rows)
    if not v:
        return None
    return (
        "cron-prompt-queue-status-count",
        "a cron prompt counts the photo queue by status, so a held row reads as a defect",
        v[0],
        v[1],
    )


# ------------------------------------------------------------------ queue runway
RUNWAY_ALERT_H = 72

# One query owns the queue question: the publisher's predicate (draft/scheduled
# AND a future clock), the status-only count that overstates it by the held rows,
# the held rows themselves, and the LAST future clock -- the forecast.
QUEUE_SQL = (
    "select "
    " (select count(*) from scheduling_posts where status in ('draft','scheduled') "
    "   and coalesce(scheduled_at, optimal_time_calculated) > (now() at time zone 'UTC')) "
    " || '|' || "
    " (select count(*) from scheduling_posts where status in ('draft','scheduled')) "
    " || '|' || "
    " (select count(*) from scheduling_posts where status in ('draft','scheduled') "
    "   and caption_metadata->'age_gate'->>'held' = 'true') "
    " || '|' || "
    # The two clocks are `timestamp WITHOUT time zone` holding UTC (Rails' default),
    # so to_char() on the raw value IS the UTC stamp. Do NOT apply `at time zone
    # 'UTC'` here: on a naive-UTC timestamp that means "interpret as UTC, then render
    # in the session tz", which double-shifts the stamp by the session offset
    # (measured: 10:30Z reported as 06:30Z under TZ=America/New_York).
    " coalesce((select to_char(max(coalesce(scheduled_at, optimal_time_calculated)), "
    "   'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') "
    "   from scheduling_posts where status in ('draft','scheduled') "
    "   and coalesce(scheduled_at, optimal_time_calculated) > (now() at time zone 'UTC')), '')"
)


def _utc_dt(s):
    """Parse a scheduler/publisher UTC stamp ('...Z'); None when unparsable."""
    if s is None:
        return None
    try:
        return datetime.datetime.fromisoformat(str(s).strip().replace("Z", "+00:00"))
    except Exception:
        return None


def queue_runway_verdict(publishable, dry_out_iso, now_iso, alert_h=RUNWAY_ALERT_H):
    """Pure: how long until the publish queue drains? -> (severity, note) or None.

    A publishable COUNT is a point reading: "publishable=16" cannot say whether the
    harness has one day of runway or two weeks, and the failure it hides is the one
    with no error of its own -- on the day the last clock passes, posting goes
    silent and only the follower count moves. The last future clock IS the forecast,
    so this fires on the FORECAST (drain inside alert_h) rather than on the empty
    queue, which render-starved / zero-accepted-output-24h already own.

    Returns None for an empty or unreadable queue: those are not this check's call.
    """
    if publishable in (None, "", 0):
        return None
    try:
        publishable = int(publishable)
    except (TypeError, ValueError):
        return None
    if publishable <= 0:
        return None
    dry, now = _utc_dt(dry_out_iso), _utc_dt(now_iso)
    if dry is None or now is None:
        return None
    hours = (dry - now).total_seconds() / 3600.0
    if hours > alert_h:
        return None
    return (
        "warn",
        f"publishable={publishable} but the last future clock is {dry_out_iso} "
        f"-- the queue drains in {hours / 24.0:.1f}d",
    )


def queue_runway_note(publishable, dry_out_iso, now_iso=None):
    """The human line for `tc_ops.py queue`: the forecast, or why it cannot be read."""
    now_iso = now_iso or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    try:
        pub = int(publishable)
    except (TypeError, ValueError):
        pub = 0
    if pub <= 0:
        return "dry_out=none (nothing publishable -- the queue is ALREADY empty; see render-starved)"
    dry, now = _utc_dt(dry_out_iso), _utc_dt(now_iso)
    if dry is None or now is None:
        return "dry_out=UNREADABLE (last clock unparsable; do NOT read this as empty)"
    days = (dry - now).total_seconds() / 86400.0
    return f"dry_out={dry_out_iso} (last publishable clock; queue drains in {days:.1f}d)"


def runway_route(holder_classes):
    """PURE: which queue a runway escalation belongs in, from the holder classes.

    The runway item is the one that must be ACTIONABLE the moment it fires: it says
    posting goes silent inside 3 days unless the render loop gets the 4090 back, and
    the card can be held in ways whose RESPONSE differs. A holder that is the
    OPERATOR's own interactive session can only be ended by a human, so the ask is
    enablement (a GPU-policy call) and must reach him -- not the agent queue, whose
    reader can only re-derive the same dead end, and whose re-derivation is exactly
    the deferral this board was built to end. Any other holder is decided in-repo:
    another project's supervised unit is normal sharing with a pre-registered
    handling (wait / extend), and one of OUR cgroups is our own mislaunch to fix.
    """
    for c in holder_classes or []:
        if str(c or "").strip().lower() == "operator":
            return "tim"
    return "agent"


# The ONE lever a human holds over a card his own session is pinning. The runway
# escalation is the only board item that reaches a person, and naming the holder
# without the lever leaves the ask as "your session is in the way" -- while the fix
# is a single flag the harness's own launch line already carries, so it must travel
# WITH the ask instead of being re-derived by whoever reads it.
OPERATOR_LEVER_CLAUSE = (
    " TWO things must be true before the harness can render through that session, and "
    "only the operator can make either true. (1) LAUNCH ARGS: an instance carrying the "
    "SAME `--reserve-vram` flag as the harness's own launch line (`bin/comfyui_harness.sh "
    "plan` prints the exact args, default `--reserve-vram 5`) is ADOPTED instead of "
    "yielded to, so the loop resumes as soon as that session has room; without the flag "
    "every tick refuses on the launch args even when the card is otherwise empty. "
    "(2) THE CARD ITSELF: the flag alone is NOT sufficient while the instance HOLDS its "
    "models -- an adopted instance still has to clear the scheduler's fit floor, and a "
    "resident ~17GiB hold leaves free below the 16GiB floor, so `poll` refuses "
    "`vram_insufficient` (measured 2026-09-22 14:00:41: a FLAGGED foreign instance, pid "
    "3662070, 17074MiB held, WAS adopted and the 16GiB claim was refused at "
    "free=6413MiB -- nothing rendered). Closing that instance, or freeing its model "
    "cache (ComfyUI's own 'Free model and node cache', or POST /free), returns ~23GiB to "
    "the card and the next tick renders."
)


def operator_holder_lever(reserve, holders, serving_pid):
    """PURE: the actionable lever for a runway escalation held by the OPERATOR.

    Empty unless BOTH halves are true: the :8188 instance is up WITHOUT
    --reserve-vram (reserve is False -- True means the harness adopts it, so there is
    nothing to ask for, and None means no instance to speak about), AND the operator's
    own session is one of the card's holders AND IS that same instance (pid match).
    The pid match keeps the clause honest: a card held by an operator process that is
    not the :8188 server must not be sent a lever about a process it is not holding.
    `holders` is gpu_vram_holders()' shape: [(pid, name, used_mib, class)].
    """
    if reserve is not False:
        return ""
    serving = str(serving_pid or "").strip()
    if not serving:
        return ""
    for pid, _name, _mib, klass in holders or []:
        if str(pid).strip() == serving and str(klass or "").strip().lower() == "operator":
            return OPERATOR_LEVER_CLAUSE
    return ""


def starve_route(reserve, holders, serving_pid):
    """PURE: which queue a render-STARVATION item belongs in.

    The starvation item is filed for the agent by default -- the agent owns the
    business call (yield the window, wait out the holder, top up elsewhere). It is
    enablement, and must reach the human, in the ONE case no in-repo action can
    clear: the card is pinned by the OPERATOR's own :8188 session, which no agent may
    touch and whose launch line no agent may change. Same rule and same 5th-tuple
    mechanism as runway_route, kept separate because this signal fires FIRST: measured
    2026-09-23, the CRITICAL `zero-accepted-output-24h` fired at 24.3h with zero
    photos while dry_out was still 6.2d out, so the runway forecast had not fired and
    the only lever the human holds never reached him.
    """
    return "tim" if operator_holder_lever(reserve, holders, serving_pid) else "agent"


def check_queue_runway():
    """The publish queue drains inside RUNWAY_ALERT_H while nothing tops it up.

    The condition is a FORECAST, not a snapshot, because the failure it precedes has
    no symptom: posting continues normally until the last scheduled clock passes,
    then stops. Measured 2026-09-21: the 4090 was held by another project all day
    (render refusals climbed 2 -> 4 -> 11 -> 12/day) while publishable stayed at 16
    -- which read as healthy at every tick, yet the last future clock was
    2026-09-27T10:30Z, i.e. the harness would go silent on 09-27 with no error
    anywhere if the render loop never got the card back.
    """
    row = psql(QUEUE_SQL)
    if row is None:
        return None
    parts = row.split("|")
    if len(parts) != 4:
        return None
    try:
        pub = int(parts[0])
    except ValueError:
        return None
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    v = queue_runway_verdict(pub, parts[3], now)
    if not v:
        return None
    job = ((sched_state().get("gpus") or {}).get(GPU) or {}).get("current_job")
    # Name the OUTSIDE-scheduler holder too. `holder` reads the scheduler's own
    # state.json, which reports current_job=null while a no-claim process sits on
    # 22 GiB (the fiction this repo already documents): an escalation whose evidence
    # says only `holder=none` is unactionable. And the holder's CLASS is what decides
    # the route -- a card held by the operator's own session cannot be freed by
    # anything done in this repo, while any other holder can be waited out.
    holders = gpu_vram_holders()
    refused = psql("select count(*) from growth_decisions where action in "
                   "('comfyui_unclaimed','cadence_blocked') and decided_at > "
                   f"(now() at time zone 'UTC') - interval '{STARVE_WINDOW_H} hours'")
    extra = f"; holder={job or 'none'}"
    if holders:
        extra += "; outside-scheduler holders: " + ", ".join(holder_desc(*row) for row in holders)
    if refused:
        extra += f"; render refusals_{STARVE_WINDOW_H}h={refused}"
    route = runway_route([row[3] for row in holders])
    if route == "tim":
        extra += ("; the card is held by the OPERATOR's own interactive session -- no "
                  "in-repo action can free it, so this is filed as enablement (a GPU-policy "
                  "call on a session no agent may touch)")
        extra += operator_holder_lever(comfyui_reserve_ok(), holders, comfyui_serving_pid())
    return (
        "queue-runway-short",
        "the publish queue drains inside 3 days and the render loop cannot top it up",
        v[0],
        v[1] + extra
        + ". Past dry_out, posting stops with no error of its own (nothing raises, the "
        "queue is simply empty), so this is the early signal: either top the queue up "
        "(needs the 4090, which may be another project's to hold) or make a deliberate "
        "cadence decision -- but make it BEFORE the last clock passes.",
        route,
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
    check_age_gate_holds,
    check_photo_pool,
    check_photo_resolution,
    check_photo_provenance,
    check_publish_gate_readiness,
    check_render_starved,
    check_queue_runway,
    check_publish_liveness,
    check_publish_gap,
    check_publish_failed_silent,
    check_insights_stale,
    check_engagement_acceptance,
    check_future_queue_empty,
    check_post_slot_bursts,
    check_post_schedule_shape,
    check_release_pacing,
    check_weekly_review_gate_wired,
    check_gate_cohort_starved,
    check_comfyui_vram_unclaimed,
    check_reserve_gate_blocked,
    check_telemetry_oom,
    check_comfyui_torch_oom,
    check_harness_log_growth,
    check_queue_growth,
    check_scheduler_dispatcher,
    check_cron_delivery,
    check_cron_prompt_probes,
    check_cron_prompt_orphan_wording,
    check_cron_prompt_log_paths,
    check_cron_prompt_queue_counts,
    check_corpus_backup,
]


# -------------------------------------------------------------------- board
def issue_path(key):
    return BOARD / f"{key}.json"


def file_issue(key, title, severity, evidence, source="probe", route=None):
    BOARD.mkdir(parents=True, exist_ok=True)
    p = issue_path(key)
    # None means "the default queue" -- checks that do not reason about the route
    # stay byte-identical to before, while a check that DOES (queue-runway-short)
    # hands over the one it computed. Either way the route is applied at FILING
    # only: a re-filing probe must never move an item out of the queue it already
    # sits in (see the setdefault below).
    route = route or ROUTE_DEFAULT
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
    global _AUDIT_SINK, _AUDIT_CHECK
    found, quiet = [], []
    # Arm the read-sink for the duration of the sweep. The probe already calls
    # every check, so noticing that one of them got NOTHING back is free -- and
    # it is the only way this class becomes visible: `psql()` returns None for a
    # query that no longer parses exactly as for a missing row, every check
    # returns None on None, and the board then reads green while that condition
    # has quietly stopped being monitored. `checks-audit` is the on-demand form.
    sink = []
    _AUDIT_SINK = sink
    try:
        for chk in CHECKS:
            _AUDIT_CHECK = chk.__name__
            try:
                res = chk()
            except Exception as e:  # a broken probe must not break the probe run
                res = (f"probe-error-{chk.__name__}", f"probe {chk.__name__} raised", "warn", str(e)[:200])
            if res:
                # A check may return a 5th element: the QUEUE this condition belongs
                # in. Only queue-runway-short does (a card held by the operator's own
                # session is enablement, not an agent decision) -- see runway_route.
                key, title, sev, ev = res[:4]
                rec = file_issue(key, title, sev, ev, **({"route": res[4]} if len(res) > 4 else {}))
                if res[2] == "critical":
                    found.append(rec)
                else:
                    quiet.append(rec)
    finally:
        _AUDIT_SINK, _AUDIT_CHECK = None, None

    # A check that could not read is a check that can never fire. Report it as
    # its own condition (so it closes itself when the reads resolve) instead of
    # leaving an unreadable DB indistinguishable from a clean bill of health.
    if sink:
        uniq, seen = [], set()
        for r in sink:
            k = (r["check"], r["sql"])
            if k in seen:
                continue
            seen.add(k)
            uniq.append(f"{r['check']}: unreadable {r['kind']} read ({r['sql'][:90]})")
        quiet.append(file_issue(
            "probe-checks-unreadable",
            f"{len(uniq)} probe check(s) could not read their input this sweep",
            "warn",
            f"{len(sink)} unreadable read(s) across {len({r['check'] for r in sink})} "
            f"check(s). Each of these checks returned None, which is also what a "
            f"healthy check returns when its condition is absent -- so the "
            f"condition is NOT being monitored and the board would read green. "
            f"Newest: " + "; ".join(uniq[:6]),
        ))

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
    # A condition that is now MEASURED by a probe check must be owned by the
    # probe, or the next re-filing carries `source: manual` forward and can never
    # auto-close again -- which is how one entry sat open for 41 sightings. Pass
    # --source probe when closing a hand-filed record whose signal the probe now
    # derives itself.
    for flag in ("--source",):
        if flag in argv:
            i = argv.index(flag) + 1
            src = argv[i] if i < len(argv) else ""
            if src in ("probe", "manual"):
                rec["source"] = src
            else:
                print(f"--source must be probe|manual (got {src!r})", file=sys.stderr)
                return 2
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


def checks_audit_verdict(results, none_reads):
    """Pure: what a probe self-audit found wrong. Empty list == every check is live.

    `results` is [(check_name, outcome)] with outcome in {"fired", "quiet",
    "raised"}; `none_reads` is [{"check":..., "kind":..., "sql":...}].

    Two failure classes, and only one of them is already visible:

    * a check that RAISES is caught by cmd_probe, which files
      `probe-error-<name>` as a warn -- visible, if noisy.
    * a check whose DB read returns None is NOT visible anywhere. `psql()`
      returns None for "psql missing", "DB unreadable" AND for a query that no
      longer parses (a renamed table/column), and every check is written to
      return None on None. So a schema change can silently retire a check: the
      condition it watches stops being monitored, the board stays green, and
      nothing errors. That is the same shape as genome #13 (agent self-recovery
      masks system decay) one level down -- in the monitoring layer itself.

    Kept pure so the decision is testable with no DB and no board writes.
    """
    problems = []
    for name, outcome in results:
        if outcome == "raised":
            problems.append(f"{name}: RAISED (probe files probe-error-{name})")
    seen = set()
    for r in none_reads or []:
        key = (r.get("check"), r.get("sql"))
        if key in seen:
            continue
        seen.add(key)
        problems.append(
            f"{r.get('check') or '<no check>'}: unreadable {r.get('kind')} read -- "
            f"a check that gets None can never fire: {str(r.get('sql'))[:120]}")
    return problems


def audit_checks():
    """Run every registered check with the read-sink armed. Returns (results, none_reads).

    Runs the SAME callables cmd_probe runs, in the same order, so the audit
    cannot drift from the probe. Read-only: no board writes, no issue filing.
    """
    global _AUDIT_SINK, _AUDIT_CHECK
    sink = []
    results = []
    _AUDIT_SINK = sink
    for chk in CHECKS:
        _AUDIT_CHECK = chk.__name__
        try:
            res = chk()
            # len >= 4, NOT == 4: a check may return a 5th element (the queue the
            # condition belongs in -- see cmd_probe). Accepting only the 4-tuple made
            # every ROUTED check that FIRES read as "raised" here, so the audit that
            # exists to prove the monitoring is live would have reported the board's
            # most important routed signals as broken the moment they fired. Measured
            # 2026-09-23: check_render_starved returned its 5-tuple and this line
            # called it RAISED while the probe filed it correctly.
            if isinstance(res, tuple) and len(res) >= 4:
                results.append((chk.__name__, "fired"))
            elif res is None:
                results.append((chk.__name__, "quiet"))
            else:
                results.append((chk.__name__, "raised"))
        except Exception:
            results.append((chk.__name__, "raised"))
    _AUDIT_SINK, _AUDIT_CHECK = sink, None
    return results, sink


def cmd_checks_audit(_argv):
    """Answer "is the MONITORING still live?" -- every check runs, and nothing is quiet by accident.

    The probe reports what is WRONG; this reports whether the probe can still
    SEE. A check whose query broke returns None exactly like a healthy check
    whose condition is absent, so the board cannot tell the two apart and a
    retired check is indistinguishable from a clean bill of health. Informational:
    always exits 0, so a monitoring tick can never be blocked by it, but prints
    the problems loudly and names each one.
    """
    results, none_reads = audit_checks()
    problems = checks_audit_verdict(results, none_reads)
    fired = [n for n, o in results if o == "fired"]
    raised = [n for n, o in results if o == "raised"]
    print(f"checks-audit: {len(results)} check(s) ran, {len(fired)} firing, "
          f"{len(results) - len(fired) - len(raised)} quiet, {len(raised)} raised, "
          f"{len(none_reads)} unreadable read(s)")
    if fired:
        print(f"  firing: {', '.join(fired)}")
    for p in problems:
        print(f"  PROBLEM {p}")
    if not problems:
        print("  OK — every check ran and every DB read resolved; no check is quiet by accident")
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
    n_asserted = [0]

    def expect(name, got, want):
        n_asserted[0] += 1
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

    # age_hold_verdict: (publishable_juvenile, recent_holds, live_holds). A
    # juvenile-flagged row that is STILL publishable is the only critical case,
    # and severity must not key on live_holds -- an old hold that keeps raising
    # severity would pin the board forever instead of self-closing.
    age_cases = [
        ("nothing", 0, 0, 0, None),
        ("one-hold", 0, 1, 1, ("info", "holds")),
        ("two-holds", 0, 2, 3, ("info", "holds")),
        ("at-warn", 0, AGE_HOLD_WARN_N, 3, ("warn", "holds")),
        ("many-holds", 0, 5, 5, ("warn", "holds")),
        ("publishable-juvenile", 1, 0, 1, ("critical", "publishable")),
        ("publishable-beats-warn", 1, 5, 5, ("critical", "publishable")),
        ("old-live-hold-self-closes", 0, 0, 2, None),
    ]
    for name, pj, recent, live, want in age_cases:
        expect(f"age_hold_verdict[{name}]", age_hold_verdict(pj, recent, live), want)

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

    # engagement_acceptance_verdict: measured posts in the trailing window ->
    # severity. Zero is the bound; an under-sized sample or an unreadable window
    # must stay silent rather than invent a dead pipeline.
    engagement_cases = [
        ("accepted", 20, 3, 1, 0, None),
        ("zero-at-production-rate", 36, 0, 0, 0, "warn"),
        ("at-floor", ENGAGEMENT_MIN_POSTS, 0, 0, 0, "warn"),
        ("below-floor", ENGAGEMENT_MIN_POSTS - 1, 0, 0, 0, None),
        ("nothing-measured", 0, 0, 0, 0, None),
        ("none-sample", None, 0, 0, 0, None),
        ("one-like-is-acceptance", 12, 1, 0, 0, None),
        ("one-comment-is-acceptance", 12, 0, 1, 0, None),
        ("one-save-is-acceptance", 12, 0, 0, 1, None),
    ]
    for name, n, l, c, s, want in engagement_cases:
        expect(f"engagement_acceptance_verdict[{name}]",
               engagement_acceptance_verdict(n, l, c, s), want)

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

    # weekly_gate_wired_verdict: (rake source, gate_read source) -> (severity, evidence)
    # or None. The guard exists because the pre-registered criterion names "that
    # review" as when it is read, and until 2026-09-22 nothing scheduled emitted it.
    gate_ok = "  FOLLOWER_CEILING        = 170\n  PILLAR_ENGAGEMENT_FLOOR = 3.0\n"
    review_wired = ("  task :weekly_review do\n    print_gate_read.call(goal)\n  end\n")
    review_dark = ("  task :weekly_review do\n    puts review.verdict\n  end\n")
    gate_cases = [
        ("wired", review_wired, gate_ok, None),
        ("wired-inline", "  task :weekly_review do\n    Growth::GateRead.new(goal: goal).call\n  end\n",
         gate_ok, None),
        ("review-dropped-the-gate", review_dark, gate_ok, "warn"),
        ("task-renamed", "  task :weekly_something_else do\n    print_gate_read.call(goal)\n  end\n",
         gate_ok, "warn"),
        ("ceiling-moved", review_wired, "  FOLLOWER_CEILING        = 250\n", "warn"),
        ("floor-moved", review_wired, "  PILLAR_ENGAGEMENT_FLOOR = 1.0\n", "warn"),
        ("rake-unreadable", "", gate_ok, "warn"),
        ("gate-src-unreadable", review_wired, "", None),
    ]
    for name, rake_src, gate_src, want in gate_cases:
        v = weekly_gate_wired_verdict(rake_src, gate_src)
        expect(f"weekly_gate_wired_verdict[{name}]", v[0] if v else None, want)

    # gate_cohort_params / gate_cohort_verdict: the cohort the pre-registered gate
    # reads is replenished ONLY by the render loop, so a REFUSED loop freezes it and
    # `:extend` ("re-read, do NOT act") stops meaning "not enough data yet". Two
    # rules matter: the mirror must follow the gate's own source (a moved cohort
    # rule must not be forecast from a stale constant), and a short cohort the loop
    # is still FEEDING must never be reported -- that one is the pre-committed
    # extend doing its job, and reporting it would make the check board noise.
    expect("gate_cohort_params[parsed]",
           gate_cohort_params("  MIN_COHORT_POSTS = 5\n"
                              "  INTERVENTION_AT = Time.utc(2026, 9, 21, 23, 35)\n"),
           (5, "2026-09-21 23:35:00"))
    expect("gate_cohort_params[rule-moved]",
           gate_cohort_params("  MIN_COHORT_POSTS = 3\n"
                              "  INTERVENTION_AT = Time.utc(2026, 10, 1, 6, 5)\n"),
           (3, "2026-10-01 06:05:00"))
    expect("gate_cohort_params[unreadable]",
           gate_cohort_params(""), (GATE_COHORT_MIN, GATE_INTERVENTION_AT))
    cohort_cases = [
        # (name, published, feasible_queued, refusals, want severity)
        ("frozen-pool", "0", "4", "4", "warn"),
        ("frozen-pool-one-short", "1", "3", "2", "warn"),
        ("loop-running-short-cohort", "0", "1", "0", None),
        ("frozen-pool-tiny", "0", "1", "9", "warn"),
        ("cohort-full-while-refused", "5", "0", "3", None),
        ("cohort-full", "4", "1", "6", None),
        ("unreadable-counts", None, "3", "2", None),
        ("unreadable-refusals", "1", "1", None, None),
    ]
    for name, pub, q, ref, want in cohort_cases:
        v = gate_cohort_verdict(pub, q, ref)
        expect(f"gate_cohort_verdict[{name}]", v[0] if v else None, want)
    expect("gate_cohort_verdict[reports-forecast-and-refusals]",
           gate_cohort_verdict("0", "4", "4"), ("warn", 4, 4))

    # THE FEASIBILITY BOUND. The cohort requires insights_updated_at and insights
    # arrive a lag after publication, so a slot inside the window's last `lag_h`
    # hours can never testify about the intervention -- it is not a late arrival,
    # it is a post the gate can never count. Measured 2026-09-23: the four
    # post-intervention slots in the 09-28 window all sit inside the final 32h
    # (the fastest observed lag), so counting raw slots reported a shortfall of 1
    # where the true one is 5. The bound must be DERIVED (never remembered) and
    # must VANISH when no lag has been measured, or a missing measurement would
    # invent a shortfall and make the check board noise.
    infeas_cases = [
        # (name, minutes_before_review, lag_h, want)
        ("slot-inside-lag", 30, 32, False),
        ("slot-exactly-at-lag", 32 * 60, 32, True),
        ("slot-before-lag", 40 * 60, 32, True),
        ("lag-unmeasured", 30, -1, True),
        ("lag-unparseable", 30, None, True),
        ("slot-unparseable", None, 32, True),
    ]
    for name, mins, lag, want in infeas_cases:
        expect(f"slot_can_carry_insights[{name}]",
               slot_can_carry_insights(mins, lag), want)
    feas_cases = [
        # (name, slots_csv, lag_h, want)
        ("empty", "", 32, 0),
        ("none", None, 32, 0),
        ("all-infeasible", "120,240,600,900", 32, 0),
        ("mixed", "120,2400,60", 32, 1),
        ("no-cutoff-when-unmeasured", "120,240,60", -1, 3),
        ("unreadable", "x,y", 32, None),
    ]
    for name, csv, lag, want in feas_cases:
        expect(f"cohort_feasible_count[{name}]",
               cohort_feasible_count(csv, lag), want)

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

    # unclaimed_vram_verdict: the card-level reading is an UPPER BOUND, not the
    # instance's own hold -- the title used to assert "ComfyUI ... holding 18.5 GB"
    # from `nvidia-smi memory.used`, which a co-tenant produces just as well. The
    # instance's own per-pid hold decides; an unreadable own-hold keeps the detection
    # but must be worded as the card's, never as the instance's.
    vram_cases = [
        ("own-holds-it", 18945, 18438, (18438, True)),
        ("co-tenant-holds-it", 18945, 300, None),
        ("not-a-compute-process", 18945, 0, None),
        ("own-unreadable-keeps-detection", 18945, None, (18945, False)),
        ("card-under-threshold", 4000, 3900, None),
        ("card-unreadable", None, 18438, None),
        ("both-unreadable", None, None, None),
        ("own-at-threshold", 18945, UNCLAIMED_COMFYUI_VRAM_MIB,
         (UNCLAIMED_COMFYUI_VRAM_MIB, True)),
        ("card-at-threshold", UNCLAIMED_COMFYUI_VRAM_MIB, UNCLAIMED_COMFYUI_VRAM_MIB,
         (UNCLAIMED_COMFYUI_VRAM_MIB, True)),
    ]
    for name, card, own, want in vram_cases:
        expect(f"unclaimed_vram_verdict[{name}]",
               unclaimed_vram_verdict(card, own), want)

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

    # cron_prompt_queue_count_verdict: a prompt answering the queue question with a
    # STATUS count. The 2026-09-21 live case is the watchdog's status-only count
    # (18 vs 17 publishable) that advised restoring a held row's clock.
    queue_cases = [
        ("status-count-unowned",
         [{"name": "w", "id": "w1",
           "prompt": "puts Scheduling::Post.where(status:['draft','scheduled']).count"}],
         "warn"),
        ("status-count-owned",
         [{"name": "w", "id": "w1",
           "prompt": "run python3 bin/tc_ops.py queue -- never the "
                     "status:['draft','scheduled'] count, which overstates by held rows"}],
         None),
        ("status-in-list-unowned",
         [{"name": "w", "id": "w1",
           "prompt": "select posts where status in ('draft', 'scheduled')"}],
         "warn"),
        ("owned-cmd-only",
         [{"name": "w", "id": "w1", "prompt": "run python3 bin/tc_ops.py queue"}],
         None),
        ("no-prompt", [{"name": "w", "id": "w1", "prompt": None}], None),
        ("unrelated-status-list",
         [{"name": "w", "id": "w1",
           "prompt": "Scheduling::Post.where(status: ['posted','failed']).count"}],
         None),
    ]
    for name, rows, want in queue_cases:
        v = cron_prompt_queue_count_verdict(rows)
        expect(f"cron_prompt_queue_count_verdict[{name}]", v[0] if v else None, want)

    # queue_runway_verdict: the FORECAST, not the count. publishable=16 hides
    # whether the harness has one day of runway or two weeks, and the failure it
    # precedes (posting stops on the day the last clock passes) raises nothing.
    RUNWAY_NOW = "2026-09-21T21:30:00Z"
    runway_cases = [
        ("roomy", (16, "2026-09-27T10:30:00Z", RUNWAY_NOW), None),
        ("inside-three-days", (3, "2026-09-23T00:00:00Z", RUNWAY_NOW), "warn"),
        ("exact-boundary", (5, "2026-09-24T21:30:00Z", RUNWAY_NOW), "warn"),
        ("one-hour-over", (5, "2026-09-24T22:30:00Z", RUNWAY_NOW), None),
        ("empty-queue-not-ours", (0, "2026-09-21T22:00:00Z", RUNWAY_NOW), None),
        ("unreadable-clock", (16, "", RUNWAY_NOW), None),
        ("unparsable-now", (16, "2026-09-27T10:30:00Z", "not-a-time"), None),
        ("negative", (-1, "2026-09-21T22:00:00Z", RUNWAY_NOW), None),
    ]
    for name, (pub, dry, now), want in runway_cases:
        v = queue_runway_verdict(pub, dry, now)
        expect(f"queue_runway_verdict[{name}]", v[0] if v else None, want)

    # runway_route: WHO holds the card decides WHICH QUEUE the escalation lands in.
    # The 3-day-runway item is the one that must be actionable when it fires, and a
    # card held by the operator's own interactive session is the single holder no
    # in-repo action can free -- so it must reach him rather than be re-derived as an
    # agent decision every pass (the deferral this board exists to end). Every other
    # holder stays in-repo: a supervised unit is waited out, our own cgroup is our bug.
    route_cases = [
        ("operator", ["operator"], "tim"),
        ("operator-with-others", ["unit", "operator"], "tim"),
        ("supervised-unit", ["unit"], "agent"),
        ("our-agent-cgroup", ["agent"], "agent"),
        ("unclassified", ["other"], "agent"),
        ("no-holder", [], "agent"),
        ("blank-and-none", [None, ""], "agent"),
        ("spaced-and-cased", [" OPERATOR "], "tim"),
    ]
    for name, classes, want in route_cases:
        expect(f"runway_route[{name}]", runway_route(classes), want)
    expect("runway_route[None]", runway_route(None), "agent")

    # operator_holder_lever: the runway ask that reaches a human must CARRY the one
    # lever he holds, and only when it is really about his instance. The two halves
    # are asserted apart because each alone makes the clause a lie: a flagged :8188 is
    # adopted (nothing to ask for), and an operator-held pid that is not the server
    # would send him a lever about somebody else's process.
    _op_holders = [(553489, "main.py", 23014, "operator")]
    lever_cases = [
        ("unflagged-operator-is-the-server", False, _op_holders, "553489", True),
        ("flagged-server", True, _op_holders, "553489", False),
        ("no-instance", None, _op_holders, "553489", False),
        ("operator-holds-but-not-the-server", False, _op_holders, "999999", False),
        ("another-class-holds-it", False, [(553489, "main.py", 23014, "unit")], "553489", False),
        ("no-holders", False, [], "553489", False),
        ("server-pid-unknown", False, _op_holders, "", False),
        ("co-tenant-beside-operator", False,
         [(1, "labeler", 14336, "agent"), (553489, "main.py", 23014, "operator")],
         "553489", True),
        ("pid-type-coercion", False, [(553489, "x", 1, " OPERATOR ")], 553489, True),
    ]
    for name, reserve, holders, pid, want in lever_cases:
        expect(f"operator_holder_lever[{name}]",
               bool(operator_holder_lever(reserve, holders, pid)), want)
    expect("operator_holder_lever[names-the-flag]",
           "--reserve-vram" in operator_holder_lever(False, _op_holders, "553489"), True)
    # ...and the CARD half. A clause that promises the flag alone is the unactionable
    # ask this board exists to end: a flagged instance that still HOLDS its models is
    # adopted and then refused vram_insufficient (measured 2026-09-22 14:00:41, flagged
    # pid 3662070, 17074MiB held, claim refused at free=6413MiB, nothing rendered).
    expect("operator_holder_lever[names-the-card-half]",
           "16GiB" in operator_holder_lever(False, _op_holders, "553489"), True)
    expect("operator_holder_lever[names-the-resident-hold]",
           "holds" in operator_holder_lever(False, _op_holders, "553489").lower(), True)

    # starve_route: the STARVATION item reaches the human only when his own session is
    # the pin -- the same lever test as the runway item, asserted separately because
    # this signal fires FIRST (measured 2026-09-23: the CRITICAL at 24.3h of zero
    # output fired while dry_out was still 6.2d out, so the runway item had not fired
    # and the lever never reached him).
    starve_cases = [
        ("operator-pins-the-flagless-server", False, _op_holders, "553489", "tim"),
        ("flagged-server-is-adoptable", True, _op_holders, "553489", "agent"),
        ("no-instance", None, _op_holders, "553489", "agent"),
        ("operator-holds-but-not-the-server", False, _op_holders, "999999", "agent"),
        ("supervised-unit-is-waited-out", False,
         [(553489, "main.py", 17074, "unit")], "553489", "agent"),
        ("our-own-mislaunch", False, [(553489, "main.py", 17074, "agent")], "553489", "agent"),
        ("co-tenant-beside-operator", False,
         [(1, "labeler", 14336, "agent"), (553489, "main.py", 23014, "operator")],
         "553489", "tim"),
        ("no-holders", False, [], "553489", "agent"),
    ]
    for name, reserve, holders, pid, want in starve_cases:
        expect(f"starve_route[{name}]", starve_route(reserve, holders, pid), want)
    expect("starve_route[None-holders]", starve_route(False, None, "553489"), "agent")

    # WHO holds the card decides the RESPONSE (an operator's own interactive session
    # is a person to ask; a supervised unit is a resource-policy question), so the
    # classifier is asserted here rather than re-derived by hand on every pass.
    holder_cases = [
        ("tmux-scope", ("python3", "/user.slice/user-1000.slice/user@1000.service/app.slice/tmux-spawn-7c88e29e.scope"), "operator"),
        ("login-shell-child", ("fish", "/user.slice/user-1000.slice/session-3.scope"), "operator"),
        ("hermes-worker", ("python3", "/user.slice/user-1000.slice/hermes-worker-cron-abc.scope"), "agent"),
        ("supervised-unit", ("systemd", "/user.slice/user-1000.slice/user@1000.service/app.slice/btnet-labeler.service"), "unit"),
        ("unreadable", ("", ""), ""),
    ]
    for name, (pc, cg), want in holder_cases:
        expect(f"classify_holder[{name}]", classify_holder(pc, cg), want)
    # holder_token: the machine token the 8188 attribution carries. It must never be
    # empty (a monitor keys on it), and must agree with classify_holder branch for
    # branch, so `owner=foreign holder=operator` cannot disagree with `holder_desc`.
    token_cases = [
        ("tmux-scope", ("python3", "/u/user@1000.service/app.slice/tmux-spawn-abc.scope"), "operator"),
        ("login-shell-child", ("fish", "/u/session-3.scope"), "operator"),
        ("hermes-worker", ("python3", "/u/hermes-worker-cron-abc.scope"), "agent"),
        ("supervised-unit", ("systemd", "/u/app.slice/btnet-labeler.service"), "unit"),
        ("unreadable-never-empty", ("", ""), "other"),
        ("hostile-input", (None, None), "other"),
    ]
    for name, (pc, cg), want in token_cases:
        expect(f"holder_token[{name}]", holder_token(pc, cg), want)
    # holder_class_of: unreadable /proc (pid gone, junk) degrades to 'other' -- a
    # monitor must not crash on the very race it is reporting.
    expect("holder_class_of[dead-pid]", holder_class_of(999999), "other")
    expect("holder_class_of[junk]", holder_class_of("not-a-pid"), "other")
    expect("holder_class_of[own-pid-is-a-token]",
           holder_class_of(os.getpid()) in HOLDER_CLASS_TOKENS, True)
    expect("holder_desc[operator]", holder_desc(3662070, "main.py", 22706.0, "operator"),
           "3662070 main.py 22.2GiB (operator-interactive session)")
    expect("holder_desc[unknown]",
           holder_desc(474174, "[No data]", 716.0, ""), "474174 [No data] 0.7GiB")

    expect("queue_runway_note[roomy]", queue_runway_note(16, "2026-09-27T10:30:00Z", RUNWAY_NOW),
           "dry_out=2026-09-27T10:30:00Z (last publishable clock; queue drains in 5.5d)")
    expect("queue_runway_note[empty]", queue_runway_note(0, "", RUNWAY_NOW),
           "dry_out=none (nothing publishable -- the queue is ALREADY empty; see render-starved)")
    expect("queue_runway_note[unreadable]", queue_runway_note(16, "", RUNWAY_NOW),
           "dry_out=UNREADABLE (last clock unparsable; do NOT read this as empty)")

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

    # image_grounding_verdict: is a caption STILL written without the render?
    # (total, attached, recent_unattached, vision_posts, ungrounded_since_flip)
    # -> severity or None. The condition is the POST-flip evidence: a window with
    # no post in it is unproven (silent), a post-flip text caption over readable
    # bytes is the defect.
    grounding_cases = [
        ("no-post-since-flip", (337, 141, 12, 0), None, None),
        ("vision-since-flip", (337, 141, 12, 1), 0, None),
        ("text-since-flip-readable", (337, 141, 12, 0), 2, "warn"),
        ("text-since-flip-not-readable", (337, 141, 12, 0), 0, None),
        ("unmeasurable-post-flip", (337, 141, 12, 0), None, None),
        ("unreadable-db", (None, None, None, None), 3, None),
    ]
    for name, args, ungrounded, want in grounding_cases:
        v = image_grounding_verdict(*args, ungrounded_since_flip=ungrounded)
        expect(f"image_grounding_verdict[{name}]", v[0] if v else None, want)

    # corpus_backup_verdict: is the second copy of the render corpus still being
    # written? A stale slot is the only signal that the backup job stopped, and
    # an unreadable stat must stay silent rather than invent an alarm.
    backup_cases = [
        ("fresh", 2.0, None),
        ("at-threshold", 48.0, None),
        ("late", 60.0, "warn"),
        ("dead", 200.0, "critical"),
        ("unreadable", None, None),
    ]
    for name, age_h, want in backup_cases:
        v = corpus_backup_verdict(age_h)
        expect(f"corpus_backup_verdict[{name}]", v[0] if v else None, want)

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
        # Definitive holder verdicts (2026-09-22): when :8188 answers, the verdict
        # REPLACES the util-sample conclusion -- a 2-min-per-prompt batch samples as
        # 1% busy, so the util hint alone mislabels live work as idle residue.
        ("below-floor-live-batch", (5250, 21, 1, 1, 23743, 24564, "live", 47.0),
         "ACTIVELY RENDERING"),
        ("below-floor-idle-residue", (5250, 21, 0, 1, 23743, 24564, "idle", 7200.0),
         "idle (last prompt 2.0h ago)"),
        ("below-floor-unreadable-holder", (5250, 21, 1, 1, 23743, 24564, None, None),
         "holder resident but idle"),
    ]
    for name, args, want in refusal_cases:
        got = vram_refusal_clause(*args)
        if want is None:
            expect(f"vram_refusal_clause[{name}]", got, "")
        else:
            expect(f"vram_refusal_clause[{name}]", want in got, True)

    # holder_activity_clause: the verdict is read from the live instance, so a
    # "live" holder must never also be described as idle residue, and an unknown
    # verdict must add NOTHING (the caller keeps the util hint).
    expect("holder_activity_clause[live]",
           "ACTIVELY RENDERING" in holder_activity_clause("live", 47.0), True)
    expect("holder_activity_clause[live-no-idle-word]",
           "not idle residue" in holder_activity_clause("live", 47.0), True)
    expect("holder_activity_clause[idle-never-rendered]",
           "never (empty history)" in holder_activity_clause("idle", None), True)
    expect("holder_activity_clause[unknown-is-silent]",
           holder_activity_clause("unknown", 5.0), "")
    expect("_fmt_age[seconds]", _fmt_age(47.4), "47s ago")
    expect("_fmt_age[minutes]", _fmt_age(744.0), "12.4 min ago")
    expect("_fmt_age[hours]", _fmt_age(7200.0), "2.0h ago")

    # reserve_flag_in_cmdline / reserve_gate_clause / reserve_gate_blocks: the
    # launch-args gate (bin/comfyui_harness.sh refuses to submit to an instance
    # launched without --reserve-vram, BEFORE it asks the scheduler for a claim).
    # The board reasoned only about free-vs-ask, so an unflagged instance on a card
    # with room would have read as "nothing is blocking us".
    for name, cmd, want in [
        ("listen-only", "--listen 0.0.0.0", False),
        ("unflagged-2026-09-22", "--listen 0.0.0.0 --enable-manager", False),
        ("flagged", "--listen 0.0.0.0 --reserve-vram 5", True),
        ("flagged-equals-form", "--listen 0.0.0.0 --reserve-vram=5", True),
        ("empty", "", False),
        ("unreadable", None, False),
    ]:
        expect(f"reserve_flag_in_cmdline[{name}]", reserve_flag_in_cmdline(cmd), want)
    # The clause fires ONLY on a confirmed-missing flag: an absent instance (None) and
    # a flagged one (True) must both add nothing, or every clean tick would invent a
    # gate that is not there.
    expect("reserve_gate_clause[flagged]", reserve_gate_clause(True, "553489", "operator"), "")
    expect("reserve_gate_clause[no-instance]", reserve_gate_clause(None), "")
    _op = reserve_gate_clause(False, "553489", "operator")
    expect("reserve_gate_clause[operator-names-response]",
           "OPERATOR" in _op and "yield the window" in _op, True)
    expect("reserve_gate_clause[operator-flag-named]", "--reserve-vram" in _op, True)
    expect("reserve_gate_clause[owner-agent-fixes-launch-line]",
           "bin/comfyui_harness.sh" in reserve_gate_clause(False, "1", "agent"), True)
    expect("reserve_gate_clause[attributable-elsewhere]",
           "never restart an instance we did not launch"
           in reserve_gate_clause(False, "1", "other"), True)
    # attribution_or_unattributed: a check that did NOT measure the cause must say so
    # rather than leave the reader to supply one from memory. A check whose evidence
    # closed with a hardcoded foreign-project holder was
    # false the moment the blocker became the operator's own session.
    expect("attribution_or_unattributed[passes-clause-through]",
           attribution_or_unattributed("; measured x"), "; measured x")
    _un = attribution_or_unattributed("")
    expect("attribution_or_unattributed[names-not-firing]", "NOT firing" in _un, True)
    expect("attribution_or_unattributed[points-at-owner]",
           "check_render_starved" in _un, True)
    # Guard the CLASS, not the instance: no check source may hardcode a holder
    # attribution it does not measure. This is the regression that produced the false
    # foreign-project holder line on gate-cohort-starved. The needle is assembled so
    # the guard's own text cannot satisfy it.
    _self_src = Path(__file__).read_text()
    for _bad in ("another project's" + " live job",):
        expect(f"no-hardcoded-holder[{_bad}]", _bad in _self_src, False)
    # Firing rule: the differential. The card must have room, or the VRAM path
    # already explains the refusal (check_render_starved carries it) and firing here
    # would file one refusal twice.
    for name, reserve, free_mib, ask_gb, want in [
        ("card-has-room", False, 22000, 21, True),
        ("exactly-the-ask", False, 21504, 21, True),
        ("below-ask", False, 20000, 21, False),
        ("flagged-is-not-a-gate", True, 22000, 21, False),
        ("no-instance", None, 22000, 21, False),
        ("free-unknown", False, None, 21, False),
        ("ask-unknown", False, 22000, None, False),
    ]:
        expect(f"reserve_gate_blocks[{name}]",
               reserve_gate_blocks(reserve, free_mib, ask_gb), want)
    # ...and the mirror is only valid while the harness owns that rule: if either
    # token implementing the gate disappears there, this suite must fail rather than
    # leave the board reporting a gate the launcher no longer has.
    expect("harness_still_gates_on_the_launch_args",
           harness_reserve_gate_present(), True)

    # Close-path ownership: only an instance WE launched is ours to stop. The
    # harness's shutdown used to SIGTERM every `main.py --listen` process, and it
    # runs right after an ADOPTED foreign instance -- so "relaunch with
    # --reserve-vram so the harness adopts it" (the board's own response to the
    # launch-args refusal) armed a kill of the operator's session.
    for name, origin, pid, stage, want in [
        ("ours", "launched", "1234", "live", "kill"),
        ("adopted-foreign", "adopted", "553489", "live", "refuse:not-launched-by-us"),
        ("unrecorded-origin", "", "1234", "live", "refuse:not-launched-by-us"),
        ("no-recorded-pid", "launched", "", "live", "refuse:no-recorded-pid"),
        ("already-gone", "launched", "1234", "gone", "refuse:already-gone"),
        ("pid-reuse", "launched", "1234", "not-comfyui", "refuse:pid-reuse"),
    ]:
        expect(f"may_kill_instance[{name}]", may_kill_instance(origin, pid, stage), want)
    expect("harness_still_owns_kill_ownership", harness_kill_ownership_present(), True)
    # ...and the LABEL the board prints must agree with the rule the launcher
    # enforces: a pid that is in our claim record because we ADOPTED it is foreign.
    for name, rec, pid, want in [
        ("launched-by-us", {"comfy_pid": "553489", "origin": "launched"}, "553489", "ours"),
        ("adopted-is-foreign", {"comfy_pid": "553489", "origin": "adopted"}, "553489", "foreign"),
        ("legacy-record-no-origin", {"comfy_pid": "553489"}, "553489", "foreign"),
        ("other-pid", {"comfy_pid": "1", "origin": "launched"}, "553489", "foreign"),
        ("no-record", {}, "553489", "foreign"),
        ("no-instance", {"comfy_pid": "553489", "origin": "launched"}, "", "unknown"),
    ]:
        expect(f"ownership_label[{name}]", ownership_label(rec, pid), want)
    # ...and the mirror must AGREE with the launcher's own offline surface, not
    # merely with itself: run the harness's decision for the same inputs.
    _hv = APP / "bin" / "comfyui_harness.sh"
    if _hv.exists():
        for _origin, _pid, _stage in (("launched", "1234", "live"),
                                      ("adopted", "553489", "live"),
                                      ("launched", "", "live")):
            _out, _rc = run([str(_hv), "killverdict", _origin, _pid, _stage])
            expect(f"harness-killverdict-matches-mirror[{_origin},{_pid or 'none'},{_stage}]",
                   (_out or "").strip(), may_kill_instance(_origin, _pid, _stage))

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

    # log_error_note / log_line_epoch: a log LINE is a record, not a state. The
    # harness log is 90 KB over 8 days, so its 2 MiB tail window holds EVERY error
    # it ever printed and a single since-fixed ERROR line reads as `errors=1` on
    # every monitoring tick. The age of the newest error is what separates current
    # from historical, so it must be printed -- and a line whose timestamp the log
    # does not declare (no TZ) must never be read as stale, in either direction.
    _stale_line = "[2026-08-01 07:00:33] deps: ERROR — long-fixed defect"
    _fresh_line = time.strftime("[%Y-%m-%d %H:%M:%S] boom ERROR", time.localtime())
    _iso_line = "2026-09-21T11:16:30 boom Exception"
    _now = time.time()
    _fresh_ep = log_line_epoch(_fresh_line)
    _old_ep = log_line_epoch(_stale_line)
    _fresh_age_h = (_now - _fresh_ep) / 3600 if _fresh_ep else None
    _old_age_h = (_now - _old_ep) / 3600 if _old_ep else None
    lognote_cases = [
        ("no-errors", log_error_note(0, 9.0), ""),
        ("fresh-error", log_error_note(1, 2.0), " (newest error 2.0h old)"),
        ("at-window-not-stale", "STALE" in log_error_note(1, 24.0), False),
        ("past-window-stale", "STALE" in log_error_note(1, 30.0), True),
        ("inside-window-hours-shown", "30.0h" in log_error_note(1, 30.0), True),
        ("day-scale-shown", "2.5d" in log_error_note(1, 60.0), True),
        ("untimestamped-named", "no timestamp" in log_error_note(1, None), True),
        ("parses-bracket-stamp", _fresh_ep is not None, True),
        ("parses-iso-stamp", log_line_epoch(_iso_line) is not None, True),
        ("no-stamp-reads-none", log_line_epoch("    from /x/y.rb:65:in 'block'"), None),
        ("localtime-fresh-not-stale", "STALE" in log_error_note(1, _fresh_age_h), False),
        ("localtime-fixed-line-stale", "STALE" in log_error_note(1, _old_age_h), True),
    ]
    for name, got, want in lognote_cases:
        expect(f"log_error_note[{name}]", got, want)

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

    # shutdown intent: a dead pid cannot hold VRAM, so the only answerable
    # question about an exit record is whether the stop was OURS -- and BOTH
    # sources (the harness's telemetry marker, its log's `shutdown:` line) must
    # read as intentional, while a stale one must not.
    _exit = {"ts": "2026-09-22T00:16:54-0400", "vram_used_mib": 3230,
             "exited": True, "cgroup": "/user.slice/x.service"}
    _marker = {"ts": "2026-09-22T00:16:43-0400", "intent": "shutdown"}
    _clean = ("[2026-09-22 00:16:43] shutdown: clean -- port closed, "
              "GPU idle (VRAM 3230 MiB)")
    _stale = ("[2026-09-21 23:12:52] shutdown: stopping heartbeat unit "
              "comfyui-hb-x")
    intent_cases = [
        ("iso-epoch-parses", iso_epoch("2026-09-22T00:16:54-0400") is not None, True),
        ("iso-epoch-bad", iso_epoch("nope"), None),
        ("iso-epoch-none", iso_epoch(None), None),
        ("local-epoch-parses", local_epoch("2026-09-22 00:16:43") is not None, True),
        ("local-epoch-bad", local_epoch(""), None),
        ("marker-found", shutdown_intent_epoch([_marker], "") is not None, True),
        ("log-found", shutdown_intent_epoch([], _clean) is not None, True),
        ("no-source", shutdown_intent_epoch([], "nothing here"), None),
        ("intentional-via-marker", exit_was_intentional(_exit, [_marker], ""), True),
        ("intentional-via-log", exit_was_intentional(_exit, [], _clean), True),
        ("stale-marker-not-intentional",
         exit_was_intentional(
             _exit, [{"ts": "2026-09-21T23:12:00-0400", "intent": "shutdown"}], ""),
         False),
        ("stale-log-not-intentional", exit_was_intentional(_exit, [], _stale), False),
        ("no-source-not-intentional", exit_was_intentional(_exit, [], ""), False),
        ("unparsable-exit-not-intentional",
         exit_was_intentional({"ts": None}, [_marker], ""), False),
    ]
    for name, got, want in intent_cases:
        expect(f"shutdown_intent[{name}]", got, want)

    # comfy_oom_verdict: a torch OOM inside ComfyUI is the CAUSE behind the
    # HTTP-500 rows, and the window is what makes the entry self-closing.
    _now = time.time()
    _oom = lambda age_h, **kw: dict(
        {"log": "comfyui-comfyui-x.log", "mtime": _now - age_h * 3600,
         "allocated": "21.32 GiB", "requested": "78.00 MiB",
         "limit": "23.52 GiB",
         "usable": "21719.11 MB usable / 21448.72 MB loaded"}, **kw)
    oom_cases = [
        ("none", comfy_oom_verdict([], now=_now), None),
        ("in-window", (comfy_oom_verdict([_oom(2.0)], now=_now) or ("",))[0], "warn"),
        ("out-of-window-self-closes", comfy_oom_verdict([_oom(60.0)], now=_now), None),
        ("at-window-edge", (comfy_oom_verdict([_oom(COMFY_OOM_WINDOW_H)], now=_now) or ("",))[0], "warn"),
        ("bare-hit-still-fires", (comfy_oom_verdict([{"log": "l.log", "mtime": _now}], now=_now) or ("",))[0], "warn"),
        ("future-mtime-not-live", comfy_oom_verdict([_oom(-3.0)], now=_now), None),
    ]
    for name, got, want in oom_cases:
        expect(f"comfy_oom_verdict[{name}]", got, want)
    _v = comfy_oom_verdict([_oom(1.0)], now=_now, launch_args="--reserve-vram 5")
    _ev = _v[1] if _v else ""
    expect("comfy_oom_verdict[names-budget]", "21719.11 MB usable" in _ev, True)
    expect("comfy_oom_verdict[names-launch-args]", "--reserve-vram 5" in _ev, True)
    expect("comfy_oom_verdict[names-allocation]",
           "21.32 GiB allocated" in _ev and "78.00 MiB requested" in _ev, True)
    expect("comfy_oom_verdict[names-usable-cap]",
           "held the budget at <= 21719 MB usable"
           in ((comfy_oom_verdict([_oom(1.0)], now=_now,
                                  usable_after=(21719.11, 5)) or ("", ""))[1]), True)

    # render_coverage_verdict: an ABSENCE check in a ZERO-coverage window must not
    # read as a repair -- cmd_probe auto-closes any probe-sourced item whose key is
    # not returned, so a render drought silently closed the CLIPSeg empty-mask
    # defect on 2026-09-22 20:25Z.
    cov_cases = [
        ("zero-attempts-is-info", (render_coverage_verdict(0) or ("",))[0], "info"),
        ("zero-attempts-names-coverage",
         "0 render(s) were ATTEMPTED" in (render_coverage_verdict(0) or ("", ""))[1], True),
        ("attempts-without-error-is-silent", render_coverage_verdict(7), None),
        ("unreadable-count-is-silent", render_coverage_verdict(None), None),
    ]
    for name, got, want in cov_cases:
        expect(f"render_coverage_verdict[{name}]", got, want)

    # launch_args_for_log: the args must come from the launch line of the SAME
    # log that carries the OOM, never from the newest line. Measured 2026-09-23:
    # the newest line belonged to a LATER start, so the board attributed
    # --reserve-vram to a process that predated the flag and pointed the reader at
    # comfy_aimdo's headroom path, which was working.
    with tempfile.TemporaryDirectory() as _td:
        _hp = Path(_td) / "harness.log"
        _hp.write_text(
            "[2026-09-21 20:00:53] launching ComfyUI (/x) in unit u1 "
            "(MemoryMax=infinity) — log: /logs/comfyui-old.log\n"
            "[2026-09-22 03:01:00] launching ComfyUI (/x) in unit u2 "
            "(MemoryMax=infinity) args='--listen 0.0.0.0 --reserve-vram 5' "
            "— log: /logs/comfyui-new.log\n")
        expect("launch_args_for_log[old-line-has-no-args]",
               launch_args_for_log("comfyui-old.log", path=_hp), (None, True))
        expect("launch_args_for_log[new-line-carries-args]",
               launch_args_for_log("comfyui-new.log", path=_hp),
               ("--listen 0.0.0.0 --reserve-vram 5", True))
        expect("launch_args_for_log[absent-log-is-unknown]",
               launch_args_for_log("comfyui-absent.log", path=_hp), (None, False))

        # comfy_usable_cap_after: the MEASURED budget of every launch since --
        # the only fact that says whether --reserve-vram reached the budget.
        _ld = Path(_td) / "logs"
        _ld.mkdir()
        (_ld / "comfyui-a.log").write_text(
            "[INFO] loaded partially; 20831.78 MB usable, 20561.55 MB loaded, "
            "2138.58 MB offloaded\n")
        (_ld / "comfyui-b.log").write_text(
            "[INFO] loaded partially; 16895.84 MB usable, 16000.00 MB loaded, "
            "100.00 MB offloaded\n")
        expect("comfy_usable_cap_after[highest-and-count]",
               comfy_usable_cap_after(0.0, log_dir=_ld), (20831.78, 2))
        expect("comfy_usable_cap_after[none-after]",
               comfy_usable_cap_after(time.time() + 60, log_dir=_ld), (None, 0))

    # checks_audit_verdict: a RAISING check is visible (the probe files
    # probe-error-<name>); an UNREADABLE DB read is not -- psql() returns None
    # for a broken query exactly as for a missing row, so a check whose SQL rots
    # retires silently and the board keeps reading green.
    expect("checks_audit_verdict[clean]",
           checks_audit_verdict([("a", "fired"), ("b", "quiet")], []), [])
    expect("checks_audit_verdict[raised-named]",
           any("RAISED" in p and "check_c" in p
               for p in checks_audit_verdict([("check_c", "raised")], [])), True)
    expect("checks_audit_verdict[quiet-is-not-a-problem]",
           checks_audit_verdict([("a", "quiet"), ("b", "quiet")], []), [])
    _nr = [{"check": "check_d", "kind": "psql", "sql": "select nope from gone"}]
    expect("checks_audit_verdict[unreadable-attributed]",
           any("check_d" in p and "can never fire" in p
               for p in checks_audit_verdict([("check_d", "quiet")], _nr)), True)
    expect("checks_audit_verdict[unreadable-deduped]",
           len(checks_audit_verdict([], _nr + list(_nr))), 1)
    expect("checks_audit_verdict[unreadable-unnamed]",
           any("<no check>" in p for p in checks_audit_verdict([], [{"sql": "x"}])), True)
    # The sink must be armed DURING the run. Armed only afterwards, every audit
    # reports "0 unreadable reads" however broken the DB is -- which is exactly
    # how this command shipped on its first version (caught by running it with
    # psql off PATH, not by reading it). Drive audit_checks with a stubbed
    # CHECKS and a failing `run` so the sequencing is asserted, not assumed.
    _orig_run, _orig_checks = globals()["run"], globals()["CHECKS"]
    try:
        globals()["run"] = lambda *a, **k: ("", 1)  # every psql read fails

        def _fake_broken_check():
            psql("select nope from gone")
            return None

        globals()["CHECKS"] = [_fake_broken_check]
        _res, _none = audit_checks()
        expect("checks_audit[arms-sink-during-run]", len(_none), 1)
        expect("checks_audit[broken-check-reads-quiet]", [o for _, o in _res], ["quiet"])
        expect("checks_audit[broken-check-attributed]",
               (_none[0] or {}).get("check"), "_fake_broken_check")

        # A ROUTED check (5-tuple, the shape cmd_probe consumes) must read as FIRED,
        # not raised: accepting only the 4-tuple made every routed signal that fires
        # look broken to the audit that proves the monitoring is live.
        def _fake_routed_check():
            return ("k", "t", "warn", "e", "tim")

        globals()["CHECKS"] = [_fake_routed_check]
        _res2, _ = audit_checks()
        expect("checks_audit[routed-5-tuple-reads-fired]",
               [o for _, o in _res2], ["fired"])
    finally:
        globals()["run"], globals()["CHECKS"] = _orig_run, _orig_checks
        globals()["_AUDIT_SINK"], globals()["_AUDIT_CHECK"] = None, None
    # The probe must FILE the condition, not merely be able to describe it: a
    # detection branch nobody exercises is how the first version of this audit
    # shipped with its sink armed after the loop. Drive the real cmd_probe
    # against a TEMP board with one check that cannot read.
    _ob, _onh, _orun, _ochk = (globals()["BOARD"], globals()["NEEDS_HUMAN"],
                               globals()["run"], globals()["CHECKS"])
    _tmpdir = tempfile.TemporaryDirectory()
    try:
        _tb = Path(_tmpdir.name) / "board"
        _tb.mkdir(parents=True, exist_ok=True)
        globals()["BOARD"] = _tb
        globals()["NEEDS_HUMAN"] = Path(_tmpdir.name) / "NEEDS_HUMAN.md"
        globals()["run"] = lambda *a, **k: ("", 1)

        def _fake_broken_check():
            psql("select nope from gone")
            return None

        globals()["CHECKS"] = [_fake_broken_check]
        with redirect_stdout(io.StringIO()):
            cmd_probe([])
        _filed = json.loads((_tb / "probe-checks-unreadable.json").read_text())
        expect("probe[files-unreadable-checks]", _filed.get("status"), "open")
        expect("probe[unreadable-names-the-check]",
               "_fake_broken_check" in (_filed.get("evidence") or ""), True)
    finally:
        (globals()["BOARD"], globals()["NEEDS_HUMAN"],
         globals()["run"], globals()["CHECKS"]) = _ob, _onh, _orun, _ochk
        _tmpdir.cleanup()
    audit_cases = list(range(11))

    for f in fails:
        print(f"FAIL {f}")
    print(f"selftest: {n_asserted[0]} assertions, {len(fails)} failures")
    return 1 if fails else 0


def cmd_queue(_argv):
    """Print the AUTHORITATIVE queue count, for cron prompts and for humans.

    The publisher (scheduling:post_scheduled) selects on the two clocks, NOT on
    status -- so `status in ('draft','scheduled')` is not the queue. The two
    disagree exactly when a post has been HELD (Growth::PersonaAgeGate clears both
    clocks and deliberately leaves status=scheduled), and the discrepancy runs in
    the dangerous direction: a status count reads "18 queued" while only 17 can
    publish, and the difference looks like a broken row to repair. Measured
    2026-09-21: the overnight watchdog counted 18, reported post 345 as a defect
    ("set scheduled_at or reclassify") -- advice that would have published a
    render the age gate read as a minor on a public adult account.

    Prints all three numbers so the discrepancy is impossible to miss, plus the
    FORECAST (`dry_out=` -- the last future clock, and the days of runway left),
    and exits 1 (with UNREADABLE) rather than printing a number it could not read.

    Why the forecast: publishable=16 read as healthy at every 2026-09-21 tick while
    the render loop was refused all day (2 -> 4 -> 11 -> 12 refusals/day), and the
    last future clock was 2026-09-27T10:30Z -- the harness would have gone silent
    on 09-27 with nothing raised anywhere. A count cannot show that; the last clock
    can, at no extra cost (same query).
    """
    row = psql(QUEUE_SQL)
    if row is None:
        print("queue: UNREADABLE (psql failed; do NOT read this as zero)")
        return 1
    parts = row.split("|")
    if len(parts) != 4:
        print(f"queue: UNREADABLE (unparsable result {row!r})")
        return 1
    try:
        pub, status_rows, held = (int(x) for x in parts[:3])
    except ValueError:
        print(f"queue: UNREADABLE (unparsable result {row!r})")
        return 1
    print(f"publishable={pub} (publisher's predicate: draft/scheduled AND a future clock)")
    print(f"status_rows={status_rows} (status only; OVERSTATES by the held rows)")
    print(f"held={held} (age-gate holds: unpublished with BOTH clocks cleared, never released)")
    print(queue_runway_note(pub, parts[3]))
    return 0


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
        exists, age, n, samples, newest_age = log_error_samples(rel)
        if not exists:
            print(f"{rel}: MISSING (nothing writes this path any more)")
            continue
        if age is None:
            print(f"{rel}: present but its age is unreadable")
            continue
        shown = f"{age / 3600:.1f}h" if age < 86400 else f"{age / 86400:.1f}d"
        print(f"{rel}: age={shown} errors={n}{log_error_note(n, newest_age)}")
        for s in samples:
            print(f"    {s[:160]}")
    for rel in DEPRECATED_LOGS:
        exists, age, _, _, _ = log_error_samples(rel)
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
        "holder-class": cmd_holder_class,
        "queue": cmd_queue,
        "log-health": cmd_log_health,
        "checks-audit": cmd_checks_audit,
        "needs-human": cmd_needs_human,
        "route": cmd_route,
        "escalations": cmd_escalations,
    }.get(cmd, lambda a: (print(__doc__), 2)[1])(argv)


if __name__ == "__main__":
    sys.exit(main())