#!/usr/bin/env python3
"""Measure the GPU-FREE content containment: how many publishable photos does the
render library actually hold, and on what date does publishing go SILENT?

WHY THIS EXISTS
`Growth::LibraryFallback` is the only content source that needs no GPU: photos
already in the corpus, unposted and servable. Its own docstring carries the rule
that matters here -- "Do not size a hold against the raw candidate count;
re-measure the gates" -- because when the gates still VETOED, the raw count and
the SPENDABLE count differed by a factor of six (measured 2026-09-23/24: 51
candidates, 8 spendable). Nothing in the ops surface measured the spendable half,
so the depth got re-derived by hand and was mis-stated as "51 candidates" in an
ops report, which reads as a multi-week buffer and is really ~2.7 days.

**PRD 0007 A1 (NSFW) and B3 (realism) removed both vetoes**, so that factor is
gone: the spend path now spends every servable, unposted photo and records both
measurements on the asset, ranking a below-default one LAST rather than refusing
it. The depth this script reports is therefore the candidate count, and the
interesting annotation is no longer "how many pass" but "how many are
low_priority" -- the number the selector pushes to the back.

So the number lives here, as a COMMAND (memory cannot rot; a file in git is found
by the next agent, unlike one in a profile directory).

WHAT IT DOES (GPU-free, CPU-only, read-only apart from its two artifacts)
1. Lists the candidate set through the spend path's OWN selector
   (`Photos::ListAvailable`) -- never a reimplementation, so it can never count a
   photo the publish path cannot serve.
2. Runs the SAME gate scripts, thresholds and model dirs the spend path runs
   (`Growth::NsfwGate` -> bin/nsfw_gate.py, `Growth::RealismGate` ->
   bin/aesthetics_gate.py), in the same order, but batched: one model load per
   gate for the whole set instead of one per photo. Verdicts are per-image and
   deterministic, so the decision is identical; only the cost changes.
   NEITHER GATE VETOES (PRD 0007 A1 for NSFW, B3 for realism) -- the ONLY reject
   stage left is the BYTES check, and a below-default score is reported as
   `low_priority` (ranked last by the selector), never as a rejection. A gate
   ERROR leaves the score unmeasured; it does not reject either.
3. Writes `ops/library_depth.json` (the measured report, committed) and
   `tmp/library_depth_cache.json` (a verdict cache keyed by photo id + size +
   mtime + CACHE_VERSION, so a re-run pays only for NEW or CHANGED photos and a
   semantics change cannot silently reuse verdicts computed under the old rules).

It does NOT spend the library, post anything, touch the scheduler, or need a GPU.

USAGE
    bin/library_depth.py            # measure (uses the verdict cache)
    bin/library_depth.py --no-cache # ignore the cache (full re-measure)
    bin/library_depth.py --limit 20 # examine at most N candidates (bounded run)
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
APP_DIR = str(REPO)
REPORT = REPO / "ops" / "library_depth.json"
CACHE = REPO / "tmp" / "library_depth_cache.json"

RAILS_PREFIX = (
    "source /usr/share/rvm/scripts/rvm >/dev/null 2>&1 && "
    "rvm use 3.4.5 >/dev/null 2>&1 && "
)

# Mirror Growth::NsfwGate / Growth::RealismGate defaults. Read at call time so the
# report can name the thresholds it actually used.
NSFW_SCRIPT = os.environ.get("NSFW_GATE_SCRIPT", str(REPO / "bin" / "nsfw_gate.py"))
NSFW_MODEL = os.environ.get("NSFW_MODEL_DIR", "/mnt/nas-ai-models/gates/nsfw_image_detection")
NSFW_PYTHON = os.environ.get("NSFW_PYTHON", "/mnt/fscache/essdee/ComfyUI/venv/bin/python")
NSFW_THRESHOLD = float(os.environ.get("NSFW_THRESHOLD", "0.5"))

AES_SCRIPT = os.environ.get("AESTHETIC_GATE_SCRIPT", str(REPO / "bin" / "aesthetics_gate.py"))
AES_MODEL = os.environ.get("AESTHETIC_MODEL_DIR",
                           "/mnt/nas-ai-models/gates/aesthetics-predictor-v1-vit-large-patch14")
AES_PYTHON = os.environ.get("AESTHETIC_PYTHON", "/mnt/fscache/essdee/ComfyUI/venv/bin/python")
AES_THRESHOLD = float(os.environ.get("AESTHETIC_THRESHOLD", "4.5"))
SHARPNESS_THRESHOLD = float(os.environ.get("SHARPNESS_THRESHOLD", "30.0"))

# Bump when the VERDICT SEMANTICS change (not when a photo changes). A cached record
# carries a verdict computed under the rules in force when it was measured, so
# reusing one across a semantics change would report an old answer as a current
# measurement. v2 = PRD 0007 A1/B3: neither gate vetoes, so `low_priority` replaces
# the nsfw/realism reject stages.
CACHE_VERSION = 2

RAILS_SCRIPT = (
    "p = Persona.first;"
    "g = Growth::Goal.active.first;"
    "c = Photos::ListAvailable.call(persona: p).photos;"
    "puts({cadence: (g ? g.effective_posts_per_day.to_f : nil),"
    " candidates: c.map { |x| {id: x.id,"
    " created_at: x.created_at.utc.iso8601,"
    " path: x.servable_file_path} } }.to_json)"
)


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def run(cmd, timeout=900, cwd=None):
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=cwd)
    return p.stdout, p.stderr, p.returncode


def list_candidates():
    # rails runner reads the script from ARGV; pass it as a positional argument
    # rather than a heredoc so this script stays pipe-free and quoting-safe.
    out, err, rc = run(["bash", "-lc", RAILS_PREFIX + "bundle exec rails runner \"$1\"", "_",
                        RAILS_SCRIPT], timeout=300, cwd=APP_DIR)
    if rc != 0:
        raise SystemExit(f"rails runner failed (rc={rc}): {(err or out)[-800:]}")
    line = [ln for ln in out.splitlines() if ln.strip().startswith("{")]
    if not line:
        raise SystemExit(f"rails runner produced no JSON: {(out or err)[-800:]}")
    data = json.loads(line[-1])
    return data.get("cadence"), data.get("candidates") or []


def gate_batch(python, script, model, paths, extra_args, timeout):
    """Run one gate script over MANY images in a single invocation (one model load).

    Returns {path: parsed-json-object} for the paths that produced a line. A path
    missing from the result is an ERROR for that image, not an accept -- the gates
    are fail-closed and so is this.
    """
    if not paths:
        return {}
    cmd = [python, script, "--model", model]
    for p in paths:
        cmd += ["--image", p]
    cmd += extra_args
    out, err, rc = run(cmd, timeout=timeout, cwd=APP_DIR)
    parsed = {}
    for ln in (out or "").splitlines():
        ln = ln.strip()
        if not ln.startswith("{"):
            continue
        try:
            obj = json.loads(ln)
        except ValueError:
            continue
        if obj.get("path"):
            parsed[obj["path"]] = obj
    if rc != 0 and not parsed:
        print(f"  !! gate {Path(script).name} exited rc={rc}: {(err or out)[-300:]}", file=sys.stderr)
    return parsed


def file_key(path):
    try:
        st = os.stat(path)
    except OSError:
        return None
    return f"{st.st_size}:{int(st.st_mtime)}"


def load_cache():
    try:
        with open(CACHE) as fh:
            return json.load(fh)
    except Exception:
        return {}


def save_cache(cache):
    CACHE.parent.mkdir(parents=True, exist_ok=True)
    tmp = str(CACHE) + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(cache, fh)
    os.replace(tmp, CACHE)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=0, help="examine at most N candidates")
    ap.add_argument("--no-cache", action="store_true", help="ignore the verdict cache")
    args = ap.parse_args()

    t0 = time.time()
    cadence, cands = list_candidates()
    if args.limit:
        cands = cands[: args.limit]
    print(f"library-depth: {len(cands)} candidate(s), cadence={cadence}/day")

    cache: dict = {} if args.no_cache else load_cache()
    verdicts: dict = {}
    missing = []
    for c in cands:
        k = file_key(c["path"]) if c.get("path") else None
        hit = cache.get(str(c["id"]))
        if (hit and k and hit.get("key") == k
                and hit.get("cache_version") == CACHE_VERSION
                and hit.get("verdict") in ("accept", "reject")):
            verdicts[str(c["id"])] = hit
        else:
            missing.append(c)

    if missing:
        print(f"  measuring {len(missing)} candidate(s) (cache hits: {len(cands) - len(missing)})")
        paths = [c["path"] for c in missing if c.get("path")]
        nsfw_off = os.environ.get("NSFW_GATE_DISABLED") == "1"
        aes_off = os.environ.get("AESTHETIC_GATE_DISABLED") == "1"

        nsfw_out = {} if nsfw_off else gate_batch(
            NSFW_PYTHON, NSFW_SCRIPT, NSFW_MODEL, paths,
            ["--threshold", str(NSFW_THRESHOLD)], timeout=1800)
        nsfw_pass = [p for p in paths if (nsfw_out.get(p, {}).get("decision") == "accept")]
        aes_out = {} if aes_off else gate_batch(
            AES_PYTHON, AES_SCRIPT, AES_MODEL, nsfw_pass,
            ["--aesthetic-threshold", str(AES_THRESHOLD),
             "--sharpness-threshold", str(SHARPNESS_THRESHOLD)], timeout=1800)

        for c in missing:
            pid, path = str(c["id"]), c.get("path")
            rec: dict = {"key": file_key(path) if path else None,
                         "cache_version": CACHE_VERSION}
            n = (nsfw_out.get(path) or {}) if path else {}
            a = (aes_out.get(path) or {}) if path else {}
            if not path or not os.path.isfile(path):
                # The ONLY veto left on the spend path: Growth::LibraryFallback skips
                # a photo whose bytes are not servable.
                rec.update(verdict="reject", stage="bytes", detail="no servable file")
            else:
                # PRD 0007 A1 (NSFW) and B3 (realism): NEITHER gate vetoes. The spend
                # path spends every servable, unposted photo and records both
                # measurements on the asset row; a below-default score only makes the
                # photo LOW PRIORITY (Photos::ListAvailable ranks it last). A gate
                # ERROR is not a rejection either -- it leaves the score unmeasured,
                # which is why `unmeasured` is reported BESIDE the verdict rather than
                # folded into it.
                nsfw_score = n.get("nsfw_score")
                aes_score = a.get("aesthetic_score")
                sharp = a.get("sharpness")
                rec.update(
                    verdict="accept",
                    stage="spend-path",
                    nsfw_score=nsfw_score,
                    nsfw_flagged=(nsfw_score is not None and nsfw_score >= NSFW_THRESHOLD),
                    aesthetic_score=aes_score,
                    sharpness=sharp,
                    low_priority=(
                        (aes_score is not None and aes_score < AES_THRESHOLD)
                        or (sharp is not None and sharp < SHARPNESS_THRESHOLD)
                    ),
                    unmeasured=(nsfw_score is None or aes_score is None),
                    gates_disabled=nsfw_off or aes_off,
                )
            rec["id"] = int(pid)
            rec["path"] = path
            verdicts[pid] = rec
            cache[pid] = rec
        save_cache(cache)

    spendable = [c for c in cands if verdicts.get(str(c["id"]), {}).get("verdict") == "accept"]
    low_priority = [c for c in cands if verdicts.get(str(c["id"]), {}).get("low_priority")]
    nsfw_flagged = [c for c in cands if verdicts.get(str(c["id"]), {}).get("nsfw_flagged")]
    rejects = {}
    for c in cands:
        v = verdicts.get(str(c["id"]), {})
        if v.get("verdict") == "reject":
            rejects[v.get("stage", "?")] = rejects.get(v.get("stage", "?"), 0) + 1

    cadence_f = float(cadence) if cadence else 0.0
    extension_days = (len(spendable) / cadence_f) if cadence_f > 0 else None

    report = {
        "measured_at": now_iso(),
        "cache_version": CACHE_VERSION,
        "candidate_count": len(cands),
        "candidate_ids": sorted(c["id"] for c in cands),
        "spendable": len(spendable),
        "spendable_ids": sorted(c["id"] for c in spendable),
        "low_priority": len(low_priority),
        "low_priority_ids": sorted(c["id"] for c in low_priority),
        "nsfw_flagged": len(nsfw_flagged),
        "nsfw_flagged_ids": sorted(c["id"] for c in nsfw_flagged),
        "rejects_by_stage": rejects,
        "cadence_per_day": cadence_f or None,
        "extension_days": round(extension_days, 2) if extension_days else None,
        "thresholds": {"nsfw": NSFW_THRESHOLD, "aesthetic": AES_THRESHOLD,
                       "sharpness": SHARPNESS_THRESHOLD},
        "gates": {"nsfw_script": NSFW_SCRIPT, "aesthetic_script": AES_SCRIPT,
                  "nsfw_disabled": os.environ.get("NSFW_GATE_DISABLED") == "1",
                  "aesthetic_disabled": os.environ.get("AESTHETIC_GATE_DISABLED") == "1"},
        "elapsed_s": round(time.time() - t0, 1),
        "note": ("GPU-free containment depth: photos already rendered, unposted and "
                 "servable. Since PRD 0007 A1/B3 NEITHER gate vetoes, so `spendable` "
                 "is the whole candidate set (the only reject stage left is the bytes "
                 "check); `low_priority` is the subset below the aesthetic/sharpness "
                 "SELECTION defaults, which Photos::ListAvailable ranks last."),
    }
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    with open(REPORT, "w") as fh:
        json.dump(report, fh, indent=1, sort_keys=True)
        fh.write("\n")

    print(f"  spendable={len(spendable)} of {len(cands)} candidates "
          f"(low_priority={len(low_priority)}, nsfw_flagged={len(nsfw_flagged)}); "
          f"rejects={rejects or '{}'}")
    print(f"  cadence={cadence_f}/day -> the library buys "
          f"{extension_days if extension_days is None else round(extension_days, 2)} day(s)")
    print(f"  spendable ids: {sorted(c['id'] for c in spendable)}")
    print(f"  wrote {REPORT.relative_to(REPO)} in {report['elapsed_s']}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
