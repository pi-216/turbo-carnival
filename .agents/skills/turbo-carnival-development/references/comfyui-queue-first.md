## ComfyUI lifecycle is QUEUE-FIRST — never SIGTERM live work (2026-09-07)

ComfyUI's native `/queue` (`queue_running` + `queue_pending`) is the workload
ledger: `sync_cadence` submits renders that drain across ticks. A harness that
cold-starts, renders a couple jobs, then SIGTERMs every tick discards queued
work, forces a full model reload, and is counterproductive. The harness was
rewritten (2026-09-07) to be queue-first and ownership-aware — preserve these
rules:

- **Ownership before killing.** Record the exact PID you launched (`comfy_pid`
  in `log/comfyui_claim.json`, alongside job_id + heartbeat pid). Never SIGTERM
  a ComfyUI process you did not spawn. A foreign unclaimed instance is
  nobody's to kill — adopt it under your claim (record its pid) instead.
- **Queue guard.** `shutdown` refuses (exit 3) while `/queue` holds renders
  (running or pending) — keep the claim alive so the backlog drains. The
  `ensure` orphan self-heal likewise skips killing an orphan whose queue has
  work.
- **Adopt-or-launch.** If something already answers on 8188, `launch_comfyui`
  records that pid as ours and returns — never spawn a second instance (it
  would fail to bind and could double-book).
- **Cron brain step 4.** While `render_need` says `need=yes` + `ours=yes`, KEEP
  the claim and ComfyUI running — that is the preferred steady state under a
  backlog (each tick enqueues into the warm instance). Only `shutdown` when
  there is no need and a claim is held. Do not mandate an end-of-tick SIGTERM.

Impact notes: a mid-render kill aborts that queue job (no PNG) — the harness
sees a pending run without a PNG on its next poll (its known infra-overload
recovery path, NOT NSFW/code bug). While ComfyUI is down, the overnight
watchdog will correctly report it down; don't treat that as an error.

**Scheduler `idle` ≠ GPU free (2026-09-03):** the gpu-scheduler only knows
about CLAIMED jobs; unregistered VRAM tenants recur on Tim's box. Same day
observed two: prx-tg `production.train_production --config
experiments/gamma2-noise-scale/config.yaml` (13GB, 89% util, since Sep 02)
then `.../stratum-hq/.venv/bin/python3.14` (20.3GB, 0% util) — while
`gpu_scheduler.py status` printed `idle` the whole time. Consequence: harness
`ensure` fails with `vram_insufficient` → exit 2 → one `comfyui_unclaimed`
Decision row per tick; 20+ consecutive such rows (Sep 2–4) = an
environment-blocker signature, NOT harness drift or NSFW. Before concluding
"4090 free", cross-check `nvidia-smi --query-compute-apps=pid,used_memory,
process_name` and expect the blockage to clear only when the tenant exits.

**Status rot (runs `pending` / jobs `submitted` forever) — ROOT CAUSE FOUND AND
FIXED.** The cause was NOT the import path and not the render: **no Sidekiq process
ran for this app at all.** `Procfile.dev` declared a `worker:` line but the systemd
unit only ran the web server, so `JobPollerWorker` (the only thing that advances a
job to a terminal status) and `JobSubmitterWorker` never ran. Consequences in order:
months of rows stuck non-terminal; then `JobSubmitterWorker`, which refuses to submit
while ANY job is `submitted`/`running`, back-pressured on its own debris and stopped
submitting entirely. The render path still produced images (`ContentGenerator`
submits synchronously and polls ComfyUI directly), which is why a dead pipeline
looked alive — judge throughput from scheduled posts + `pipeline_runs.quality_metrics`,
but judge HEALTH from whether statuses advance.

Fix: `bin/run_worker.sh` + `ops/systemd/turbo-carnival-sidekiq.service`, enabled with
`systemctl --user enable --now turbo-carnival-sidekiq` (the sidekiq initializer
re-arms `JobPollerWorker` on boot). Verify with `pgrep -af sidekiq` (expect
`sidekiq ... turbo-carnival`) and by watching a new job reach `completed`. **A repo
whose Procfile declares a worker but whose unit file does not run it is the tell.**
Recovering from a rot backlog: a job is genuinely in flight only if ComfyUI still
knows its prompt id, so reconcile the rest to a terminal status BEFORE trusting any
in-flight count.

**PITFALL: an unbounded "any in-flight job" gate stalls submission permanently.**
`JobSubmitterWorker` counts `ComfyuiJob.where(status: %w[submitted running])` and
returns early when it is non-zero — no age bound, no reconciliation — so ONE phantom
row (ComfyUI restarted, or its queue was cleared by hand) halts all submission
forever. Reconcile FIRST, from the downstream system's ground truth:
`ReconcileStaleJobs` reads ComfyUI `/history` + `/queue` and terminalises anything
older than a 10-minute grace that is absent, and it runs at the top of
`JobPollerWorker#perform` so nothing counts stale rows. Parse `/queue` correctly — it
is an object (`{"queue_running": [[n, "prompt_id", {...}], ...], "queue_pending":
[...]}`), not a flat list of ids; taking `.keys()` yields the literal strings
`queue_running`/`queue_pending` and makes every job look orphaned. Do NOT
blanket-fail orphans either: ComfyUI clears `/history` on restart, so a genuinely
finished render can look absent — check whether the run already produced a photo or
scheduled post before marking it failed, or it gets re-rendered as a duplicate.

**PITFALL: a retry path that creates a bare `pending` row is a silent no-op.**
`PollJobStatus#enqueue_oom_retry` created `ComfyuiJob(status: "pending")`, but nothing
submits pending `ComfyuiJob` rows — `JobSubmitterWorker` builds NEW jobs via
`SelectNextJob` → `SubmitJob` and never sweeps pending rows — so the OOM retry
stranded its row while the run stayed failed. A retry must go through the same submit
path as the original (`SubmitJob.call(...)`), not merely create a record. Symptom to
grep for: `pending` with a NULL `comfyui_job_id`, older than ~30 min.

**Ops board — the fix loop for this project.** Monitoring existed for months but
nothing turned a detection into a closable work item, so the same failures were
re-diagnosed repeatedly. `bin/tc_ops.py` is a file-based issue board (one JSON per
STABLE key under `ops/board/`, so repeated probes refresh rather than duplicate):

```bash
python3 bin/tc_ops.py probe        # scan signals, file/refresh issues, auto-close cleared ones
python3 bin/tc_ops.py list         # open issues, severity-ordered
python3 bin/tc_ops.py close KEY --note "<what changed + how you verified>"
python3 bin/tc_ops.py file KEY --title "..." --evidence "..." [--severity warn|critical|info]
python3 bin/tc_ops.py touch KEY -n "<decision, reasoning, what remains>"
python3 bin/tc_ops.py needs-human     # rewrite the ops/NEEDS_HUMAN.md digest
```

Filing by hand: `file` is for what the probe cannot measure, then run `needs-human` and commit the board (`ops/board/<key>.json`, `ops/NEEDS_HUMAN.md`) — the hourly triage commits the board too, so leave the tree clean. `file` will NOT steal a probe-owned key (the CLI restores `source: probe`), and `--evidence-file <path>` exists because the tool scanner refuses a command line containing a raw private address or URL — quote evidence from a file rather than trimming it. `touch KEY -n` is how a `source: manual` item stops reading as blocked on a human: put the decision, its reasoning, and what remains in the note.

### Heavy commands run in their own cgroup — and their OUTPUT is captured

`bin/ops_heavy.sh <label> <command...>` (or `python3 bin/tc_ops.py heavy ...`) runs a
repo-wide lint/test/verification command in its own accounted systemd scope, outside the
cron worker's 4 GiB cgroup cap (which killed a tick mid-run: 2026-09-24 13:40:34Z, scope
named job `9c05f60f5fef`, victims ruby + node). It prints
`rc= peak_mb= cap_mb= oom_kill= isolated=yes cgroup=`, then the last 25 lines of the
command's output and the path to the full text (`log/ops_heavy-<label>.out`, gitignored).
The output capture is the part that matters for reads — before it, the child went to
/dev/null, so a command whose TEXT is the point (a gate read, an inventory count) could
not be isolated at all and had to run inline. `bin/ops_heavy_test.sh` is the no-GPU
mechanism test (rc propagation, capture, silence on an empty command, usage rc=2); the
tc-ops-triage prompt requires the runner. Light commands (`probe`, `checks-audit`, git,
psql reads) peak ~200 MB and are safe inline.

#### The board's two queues — `route` decides whose call it is (2026-09-21)

Every open item carries a `route`, and the split is the point. Read
`ops/NEEDS_HUMAN.md` at the start of a session here: it is generated, split by
route, and is the only surface that reaches anyone (this profile's crons deliver
`local`, so reports land in `cron/output/<job-id>/` and nowhere else).

- **`route=agent` (default)** — a business/product call the AGENT owns: cadence,
  persona, caption path, strategy, which lever to build, whether to wait for a GPU
  slot. Decide it and close it. This is the "DECIDE, DON'T ASK" rule above made
  machine-readable.
- **`route=tim`** — ENABLEMENT only: a file outside this repo, a credential, a
  channel/platform setting, a GPU policy — something no agent can do from here.
  Only these may be pushed to Tim (`python3 bin/tc_ops.py escalations`, which
  prints nothing when there is nothing).

```bash
python3 bin/tc_ops.py route <key> --route tim -n '<why it needs a human>'
python3 bin/tc_ops.py escalations   # the enablement queue and nothing else
```

**Why this exists:** for its first two days the board filed business decisions as
`source=manual` = "waits on a human", because nothing said the agent owned them.
Every hourly pass re-derived the same deferred item, appended a note, and closed
nothing — an item that is everyone's call is no one's. `source` says who keeps the
record; `route` says whose call it is. When you decide an item, put the DECISION
(not just the finding) in the `touch` note, then verify it against live evidence
and close it.

### Editing the board from a session — the hourly probe is writing it too

The `tc-ops-triage` probe rewrites `ops/board/*.json` (refreshing `evidence`,
`last_seen`, `seen_count`) while a session edits the same files, so a patch can be
refused with "modified since you last read". Re-read the file's TAIL immediately
before patching, and anchor the patch on the newest note's own closing text — the
trailing `}` / `]` / `}` is not unique and will not match. `notes` is append-only,
so a note that lands survives every later refresh even though the file around it keeps
moving.

### The escalation surfaces LIE in two ways — check both before trusting an ask

`route=tim` items reach Tim ONLY through `escalations` and `ops/NEEDS_HUMAN.md`, and
both are generated — so a defect in either silently deletes the ask while the board
looks fine.

- **A bounded digest must keep BOTH ENDS.** This file's convention composes the
  measured condition FIRST and the ask LAST, so a front slice (`evidence[:300]`)
  removes exactly the sentence the human needs. `human_digest` did that while
  `escalations` had already been fixed for it — measured 2026-09-23, where
  `NEEDS_HUMAN.md` read "... (see COMFY_RESERVE" and nothing more. Both now use
  `digest_elide` (middle elided, ends preserved). When you add a bounded surface,
  assert the TAIL survives, not just the length.
- **A lever must be sized to the LIVE resource, not remembered.**
  `operator_holder_lever()` returned one frozen two-condition text (ending "freeing
  its model cache … returns ~23GiB") and printed it every tick — so after the
  operator's session went idle and released its models (1.6GiB held, 21.8GiB free,
  the launch line the only remaining refusal) the digest asked him to free a cache
  that was already free. Derive the ask from the live reading (`free_mib` vs the ask
  the harness would make), keep the fuller text for the blocked AND unreadable cases,
  and extract the routing predicate so route and wording cannot disagree.
- **Never put backticks in a `tc_ops.py touch -n` argument passed through the shell**
  (or any quoted CLI note): bash command-substitutes them and the substituted word
  vanishes from the recorded note with no error — use single quotes and plain words.

### Holding a scheduled post — a status change is NOT a hold

`scheduling:post_scheduled` selects posts that are DUE by EITHER clock:
`status='scheduled'` with `scheduled_at <= now`, OR `status='draft'` with
`optimal_time_calculated <= now`. Setting a post back to `draft` therefore does NOT
remove it from the publisher. To park a post, clear BOTH `scheduled_at` and
`optimal_time_calculated`, and record the slot you cleared so it can be restored;
verify by re-reading the row with neither clock set (the queue counters drop by one,
which is the expected signal). This is a production write on a live account: make the
decision yourself, then ask for the one sign-off before executing — state it as a
single go/no-go, never as a menu.

### The REELS rail and the discovery arm — how to arm it, and the three traps

The pre-registered pivot (board item `reel-arm-unarmed`, openspec
`add-reel-discovery-arm`) publishes REELS cut from renders the harness already
produced, because the account's own insights answer `reach` with
`breakdown=follow_type` as FOLLOWER-only with NO non-follower row and
`profile_views=0` — so every still-side lever is inert by construction. The
asset/container/serving/record steps were built 2026-09-24; the ARM (2026-10-12)
added only the missing production caller:

- `Scheduling::Commands::SendReelToInstagram` (packs/scheduling) — the
  `create_reel` caller. `bin/tc_ops.py check_reel_arm_stall` scans for exactly
  `create_reel` outside specs with comments stripped, so a mention in prose does
  NOT count as an arm (a wider pattern once silenced the one check that catches a
  dropped pivot).
- `scheduling:post_reels` (`packs/scheduling/lib/tasks/reel_posting.rake`) — the
  reel rail. `scheduling:post_scheduled` deliberately EXCLUDES
  `reel_path IS NOT NULL` rows (no photo to resolve) and only COUNTS them; keep
  that split. It is LIMIT=1 per tick and runs AFTER the still rail in
  `bin/scheduled_posting.sh` (non-fatal, like the repairs).
- `Growth::ReelArm` + `growth:reel_arm[Sarah]` (packs/growth_harness) — picks the
  newest N servable renders, builds the clip, creates the post. It REFUSES when an
  unpublished reel post already exists, so re-running cannot stack external writes.
- Verified live: post 408 to IG media `18117602389787008`, `media_type: VIDEO`,
  `instagram.com/reel/DeYqy8glB_a/`; reconcile with
  `bundle exec rails instagram:media_inventory` (listed 250→251, ours 201→202).

Three traps, all paid for:

1. **A REELS post has NO photo** (`photo_id` NULL is exactly what `reel?` means,
   discriminated by `reel_path`). Anything resolving `post.photo` raises on it, and
   it is deliberately kept out of `Growth::GateRead#cohort_size` (the still cohort
   the pre-registration measures). Never "fix" that by attaching a photo — the
   `(photo_id, persona_id)` unique index then burns the render permanently.
2. **Verifying due-ness with psql lies about the clock domain.** `scheduled_at` is
   stored UTC (`Time.zone` is UTC) while a psql session compares against a LOCAL
   `now()`, so `select scheduled_at <= now()` read FALSE for a post that was
   genuinely due. Ask Rails instead — run the rail's own `where(...)` scope through
   `rails runner` before concluding a post is not due.
3. **`bin/brakeman` unshifts `--ensure-latest`**, which fails when the BUNDLED
   brakeman is not the newest release — CI's `scan_ruby` exits 5 BEFORE it scans,
   so a stale `Gemfile.lock` pin hides every real warning for as long as it drifts.
   `bundle update brakeman` first, then read the actual warnings. That flag going
   green is NOT security-clean.

CI runs `bin/brakeman` + `bin/rubocop` + `bin/rails test`, and `bin/rails test` here
runs **0 minitest tests** — the real suite is RSpec (`bin/rspec`, 712 examples 2026-10-19), so
CI does not run it: run it yourself. Lint drift accumulates invisibly while CI is
dark (9 `Style/StringLiterals` offenses landed in one rake file during the
2026-08-24..10-12 CI outage), so after any long CI-dark stretch run the whole
`bin/rubocop`, not just the files you touched.

### The second copy of the corpus — `bin/corpus_backup.sh` + cron `bae1bd85ec35` (2026-09-21)

`/mnt/nas-ai-models/comfyui-output` is the only copy of every photo this account
has posted or could post, and `/home/tim/backup.sh` mirrors it as a **dangling
symlink onto the SAME NAS volume** — it protects nothing while looking like it
does. The second copy lives at `<repo>/corpus-backup/` (gitignored, on the local
NVMe: a different machine AND a different device from the NAS), written by
`bin/corpus_backup.sh`. The Hermes cron `tc-corpus-backup` (id
`bae1bd85ec35`) runs it nightly at 03:15 from the repo workdir.

- **Scope is explicit and auditable:** top-level `/gen-*.png` plus
  `/sarah1a3/***` only — 59,704 files / 83 GB, matching 59,491 render files +
  213 top-level pngs. The other projects' trees under `comfyui-output` (A1111,
  unnamed, toy) are deliberately OUT. The DATABASE defines the corpus: every
  `photos.path` that still resolves must be present in the new snapshot or the
  run FAILS, so it cannot report success while the thing it protects is gone.
  `--verify-only` re-checks the newest slot without copying; `--list` shows slots.
- **`-L` is the whole point.** It follows symlinks so real BYTES land in the
  copy; the defect being fixed is a copy that was only a symlink.
- **Hardlink snapshots into seven weekday slots, never a dated pile that gets
  pruned.** `--link-dest` into the newest other slot means a slot costs only what
  changed — and because `PhotoAssetMarker` mutates a published asset IN PLACE
  (temp file + atomic rename), the hardlink BREAKS, so an earlier slot keeps the
  pre-mark bytes. A plain mirror silently loses that history.
- **There is no `rm -rf` anywhere in it, on purpose** — a prune step containing
  one was exactly what kept the script from executing at all (see the refusal
  note below). The seven slots ARE the retention policy: rsync replaces a slot
  when it is reused, so there is nothing to delete.
- **Off-site destination (`--offsite`, B2): probe it with `b2_tim` + the endpoint, not
  the default profile.** `aws --profile b2_tim --endpoint-url
  https://s3.us-west-004.backblazeb2.com s3 ls s3://tim-training-data/` answers rc=0 and
  lists ~18 sibling project prefixes; the DEFAULT aws profile is a different account
  (231074198977) that returns AccessDenied / no such bucket — that is NOT evidence the
  destination is missing. The write is what needs Tim's approval.
- **Verify the off-site write INDEPENDENTLY, not from the script's own log.**
  `--offsite` prints its own read-back (`sha256 matches`), which is a self-report:
  confirm the object exists with `aws --profile b2_tim --endpoint-url
  https://s3.us-west-004.backblazeb2.com s3api head-object --bucket
  tim-training-data --key turbo-carnival/corpus/<archive>` and compare BOTH
  `ContentLength` and the object's `Metadata.sha256` against the local
  `sha256sum` of the archive. That turns "the script said so" into "the bytes are
  there". `--offsite --dry-run` builds a REAL archive on the way to its dry-run
  target, so it leaves an extra tarball in `corpus-backup/offsite/` — release the
  flag from Tim first, then run it once.
- **Runtime is 10-20 min even when nothing changed** (the NFS metadata walk) and
  hours for the first full pass. Run it in the BACKGROUND and wait on it; a tick
  that ends before the copy finishes is NOT a failure. Never let a tool-call
  timeout read as a failed backup — check the slot and `--verify-only` first.
- 168 of 339 `photos` rows are already unresolvable (66 of them pointed at
  `/tmp`); the 171 that survive total 176 MiB. Those dead `path` values are a
  separate, still-open problem — this script's success is NOT a repair of them.

### This repo is PUBLIC — secret hygiene before any commit or push

`github.com/timlawrenz/turbo-carnival` is a **public** remote, so anything
committed is published. Push protection is on for public repos, which blocks a
known-format secret at push time — that is the standing guard, and it is not a
substitute for looking before you commit:

- **Tracked and correct:** `config/credentials/*.yml.enc` (encrypted).
- **Tracked and safe only because it holds REFERENCES:** `.kamal/secrets`
  (`$KAMAL_REGISTRY_PASSWORD`, `$RAILS_MASTER_KEY`) — never inline a literal
  there. `CREDENTIALS_STATUS.md` records where credentials live, no values.
- **Must stay out (all gitignored):** `config/master.key`,
  `config/credentials/*.key`, `.env*`, `corpus-backup/`, `storage/*`. A `.key`
  that ever enters history retroactively decrypts every tracked `*.yml.enc` —
  check that class stayed out, do not assume it.
- **Audit procedure + masked probe:** `requesting-code-review` skill, Step 2b,
  and `scripts/repo_secret_audit.py` there — run it with
  `--range <old-remote-tip>..HEAD` to scope what a push newly exposes separately
  from pre-existing public history.
- **Audited state (all refs):** zero hits across the AWS/B2/token/PEM pattern
  families, and no key-material file ever added. The only secret-shaped hits are
  `your_app_secret` / `your_access_token` placeholders in the READMEs, proved by
  comparing sha256 digests against the live credentials (which exist only in the
  encrypted store), plus the throwaway `postgres://postgres:postgres@localhost`
  in `ci.yml` / `database.yml`. Report a credential answer WITH its scope, and
  never print a matched value.

### Two writes that get refused, and what to do instead

- **Repo `AGENTS.md` is a protected agent-instruction file — writes to it are
  refused.** Always-on session instructions for this repo (e.g. "read the ops board
  first") belong in THIS skill, which loads whenever you work here; do not retry the
  write and do not route the same content in through the terminal.
- **Keep destructive-looking text out of command lines AND out of the CONTENTS of any
  script you invoke.** The scanner reads both. A command line that merely CONTAINS an
  `rsync … --delete` string stalls at the approval gate, and so does an otherwise-clean
  `./bin/thing.sh --dry-run` when the script FILE itself contains an `rm -rf` — the
  command line is irrelevant, the file is what gets read. Under a cron whose
  `cron_mode: deny` there is no prompt to approve, so the job silently does nothing at
  all while looking scheduled. Pass long prose through `patch`/`write_file` instead of
  the shell, and **design scripts to need no deletion primitive**: bound retention with
  a fixed rotating set of destinations that rsync replaces in place (seven weekday
  slots), rather than a prune step that deletes old ones. A script containing a delete
  cannot be run unattended, so the delete is what to remove — not the retention.

The `tc-ops-triage` cron (hourly at :25, `continuity: true`, workdir = the repo) runs
`probe`, then works each open issue: fix the ROOT CAUSE in the repo, verify with real
evidence, close with a note. Rules worth keeping when extending it: never touch
another project's GPU jobs/queue/training; file out-of-scope problems as `info`
instead of acting outside the repo; and a probe auto-closes ONLY issues it filed
itself (`source: probe`) — hand-filed issues carry `source: manual` and survive. Two
false-positive classes already paid for: a check that runs an import must set `cwd` to
the project root (a bare `import comfy.storage` fails from anywhere else), and
pin-vs-installed comparison must treat `-` and `_` as equivalent in distribution names
(`comfyui-frontend-package` installs as `comfyui_frontend_package`), and a check that
scans a log or journal must use a SHORT lookback (~15 min) — a 1-hour window keeps
reporting a condition for a full hour after it was fixed, the same crying-wolf failure
as the other two.

**A producer-side fix does not repair what is already in the queue — add the
queue-side check AND a repeatable repair, wired into the consumer.** The
hashtag repair (71e522e) fixed four breaks, all on the producer side (engine
pillar split, `Personas::HashtagStrategy#tags`, the generator's create, the
caption at send time); the publisher appends `scheduling_posts.hashtags`
verbatim, so a row created before/around the fix kept `'[]'` and would have
shipped untagged — found live on post 340, created 2 min after the commit by a
process still running pre-fix code, invisible to every hashtag probe because
they all measure the producer window. Pattern to reuse: (1) a `tc_ops.py` check
over the PERSISTED rows (`check_queued_post_hashtags`, the counterpart of
`check_placeholder_caption_queued`); (2) a command + dry-run-by-default rake task
that can redo the repair at any time (`ContentStrategy::QueuedHashtagBackfill` /
`hashtags:backfill_queued`) — the original backfill of 20 rows was a one-off
console run nothing could repeat; (3) the repair invoked NON-FATALLY by the
consumer that is about to act on the row (`bin/scheduled_posting.sh`, exactly
like the placeholder-caption repair it sits next to). Verify the code path is
healthy before calling it a code bug: `HashtagEngine.generate` returned 10 tags
for that photo under every pillar, which is what proved the empty column was a
queue artifact and not a live engine defect.

**Read the monitoring jobs' outputs BEFORE investigating an anomaly yourself.** The
hourly `tc-growth-harness-brain` (and the overnight watchdog) write a per-tick report to
`$HERMES_HOME/profiles/<profile>/cron/output/<job-id>/<timestamp>.md`, and they have been
independently diagnosing the same faults this project re-derives by hand — the memory
cap behind an OOM crash-loop, the held GPU claim starving other projects, renders
dispatched for already-terminal runs, `sync_cadence` exceeding any terminal timeout.
Re-deriving those costs hours and arrives late. First move on any "why is this broken"
question:

```bash
ls -t $HERMES_HOME/profiles/turbo-carnival/cron/output/*/ | head     # per-job-id subdirs
# then read the two or three newest reports from the project's monitoring jobs
```

Treat those reports as findings to ACT on and reconcile against the board, not as
status prose to summarise back. If a report and the board disagree, the board is the
tracked truth and the discrepancy is itself a finding.

### ComfyUI diagnostics and interactive slot hold

- **Cgroup telemetry** — `script/comfyui_telemetry.py` samples the launched ComfyUI's
  cgroup `memory.current` / `memory.peak` / `memory.events` (`oom`, `oom_kill`) plus
  `nvidia-smi` VRAM every 30 s into `log/comfyui_telemetry.jsonl`; read it with
  `bin/comfyui_harness.sh telemetry [N]`. It runs in its OWN systemd unit so it survives
  the death it is watching — a sampler inside the same scope dies with its subject and
  records nothing. This is what turns "ComfyUI vanished" into an attributable cause
  without journald archaeology; the final record carries `exited: true` and the last
  known counters. Caveat: a `--collect`ed unit takes its cgroup counters with it the
  moment systemd collects it, so the sampler can miss the final `oom_kill` increment —
  the kernel journal stays authoritative, which is why the harness also greps
  `journalctl -k` for its own unit name on death detection.
- **The harness asserts the launch cgroup** and logs `instrument: OK — launch is in its
  own unit cgroup, not the cron scope` (or an explicit ERROR when the pid landed in a
  `hermes-worker-cron-*` scope), so an isolation regression is visible AT LAUNCH instead
  of being inferred later from a corpse.
- **Interactive slot hold** — `bin/comfyui_debug_go.sh [--wait N] [--dry-run]` adopts the
  turbo-carnival entry already at the FIFO head, claims it, publishes the state file and
  hands off to `ensure` (which owns the heartbeat unit and the instrumented launch — no
  launch logic is duplicated). Use this rather than a fresh `request` when the slot is
  wanted for a human debug session: a fresh request lands BEHIND any queued entry, and
  the hourly brain keeps requesting its own ids. Safe no-op when the GPU is busy — no
  side effects, and the entry is left for the automated loop.
- **Zombie Sidekiq jobs — verify OWNERSHIP before purging; a class missing from this
  repo may belong to a SISTER project.** The first time a worker actually runs for this
  app it surfaces retry entries whose classes are not defined here
  (`TouchNeighborsJob`, `RecalculateCollectionCentroidJob`), each retrying a guaranteed
  `NameError` forever. But "not defined here" does NOT mean "dead": this app's Sidekiq
  initializer set no Redis URL, so it defaulted to `redis://localhost:6379/0`, which is
  **crawlr's** DB — our worker was consuming crawlr's jobs, and purging five of their
  retry entries destroyed another project's queued work. That is the one thing Tim
  asked not to happen. Clear this bar before deleting ANY Sidekiq entry: (1) grep the
  sibling project trees (`~/source/activity/*/`) for the class name; (2) establish which
  Redis DB the entry came from. **A purge is only safe when the class exists in NO
  project sharing that broker** — otherwise it is another team's job, and the right move
  is to stop consuming it, not to delete it. The durable fix is isolation, not cleanup:
  keep this app on its OWN Redis DB (`config/initializers/sidekiq.rb` pins
  `redis://localhost:6379/1`; crawlr is db0, t-chat db2) — verify with `redis-cli -n 1
  info keyspace` (ours, few keys) vs `-n 0` (theirs, thousands) and confirm no foreign
  queue names appear on ours. If damage was done, RE-PUSH the deleted jobs to the
  owner's DB: the exact classes and args survive in the worker journal, and recalculating
  jobs of this shape are safely re-runnable (`redis-cli -n 0 LPUSH queue:default
  '<sidekiq job json>'` needs no gem — the `redis` gem is not in this bundle, Sidekiq 7
  uses `redis-client`). The `tc_ops.py` check `sidekiq-zombie-jobs` greps the worker
  journal for `uninitialized constant` so this class of rot lands on the board instead
  of retrying silently — that check flags it, it does not license deletion.

### Harness wiring (2026-09-02, all verified live)

The cron brain + watchdog + ContentGenerator are now gated on the scheduler
claim so nothing ASSUMES ComfyUI is up:

- **bin/comfyui_harness.sh** — lifecycle engine: `status` (one line:
  `claim=<idle|busy|claimed> job=<id> ours=<yes|no> comfyui=<up|down>`),
  `ensure [--wait N]` (request→poll→activate→launch→heartbeat loop→wait for
  /system_stats; it ADOPTS its own queued entry instead of minting a fresh id per
  tick, and cancels duplicates — see "Own queued entries" below), `heartbeat`, `shutdown` (stop heartbeat loop,
  SIGTERM ComfyUI, verify port closed + GPU idle, release claim). State file:
  `log/comfyui_claim.json` (job_id + heartbeat pid + comfy_pid). ComfyUI
  launched detached with the known-good `.venv/bin/python main.py --listen 0.0.0.0`
  (no extra flags) in its own systemd unit, and it self-provisions its venv. See
  "ComfyUI lifecycle is QUEUE-FIRST"
  below for the ownership + drain rules that govern ensure/shutdown.
- **`ensure` in a foreground terminal call times out even on success** — the
  detached heartbeat loop inherits the harness's stdout, so the tool's pipe
  never EOFs and the call is killed at the tool timeout AFTER the lifecycle
  already completed (log shows "CLAIMED ... ComfyUI up after Ns"). Verify with
  `status` / `log/comfyui_claim.json` / scheduler state — never re-run on the
  timeout alone. **This no longer applies as of 2026-09-19**: the heartbeat now
  runs in its own systemd unit with stdout sent to the harness log, so `ensure`
  no longer holds the caller's pipe open and returns on its own.
- **Never run `sync_cadence` under a short shell `timeout`.** generate_one
  polls ComfyUI synchronously per render (~20s × up to 60 polls ≈ 20 min); a
  `timeout 120` foreground call SIGTERMs the poller mid-render, the run stays
  `pending`, and the finished PNG is orphaned (written to output, no importer
  ever claims it). Trace signature: `SignalException: SIGTERM` at
  `content_generator.rb:182` (`sleep POLL_INTERVAL`). Let the brain cron drive
  sync (its own timeout budget applies), or give a manual run at least
  render+poll time.
- **Only one `sync_cadence` driver per tick — CadenceEngine has no lock.** A
  manual sync racing the hourly brain cron double-drives: each recomputes
  shortfall at start, so both create runs to fill the same backlog (cadence
  overshoot). Before running sync manually, check the brain schedule in
  cron/jobs.json; when a tick is close, let the cron own the loop.
- **Growth::SchedulerGate** (`packs/growth_harness/app/services/`) — read-only
  gate calling `bin/comfyui_harness.sh status`; fail-closed. `ready?` =
  ours && comfyui up. `ContentGenerator#generate_one` calls it FIRST and
  returns `{success: false, error: 'comfyui_unclaimed'}` (plus a
  `Growth::Decision` row action `comfyui_unclaimed`) when there's no claim.
  CadenceEngine treats it as a blocking failure (not pillar-specific) —
  correct: never spam renders claim-less.
- **rake growth:render_need[Sarah]** — one line: `shortfall=N target=N
  existing=N need=yes|no claim=idle|ours|other comfy=up|down`. The brain
  calls this BEFORE touching the GPU; `need=no` → skip the GPU entirely.
- **Cron prompts** (jobs.json) — brain: step 0 GPU gate (status + render_need
  → ensure --wait 180 or skip+record decision), step 4 GPU RELEASE; watchdog:
  claim-aware ComfyUI interpretation (down-unclaimed = EXPECTED; up-unclaimed =
  ORPHANED-GPU leak, loudest finding; down-while-claimed = ANOMALY); weekly
  review: same semantics. LIVE-FILE CHECK (2026-09-16): the on-disk step-4
  wording is still "GPU RELEASE (mandatory at end of tick): run shutdown", NOT
  queue-first — the QUEUE-FIRST guarantee comes from the HARNESS (shutdown
  exit 3 refusal while /queue holds work), not the prompt. A backlogged claim
  survives a tick; an empty queue gets released next tick. To hold the GPU
  continuously (night grant, long backlog), update the prompt text in
  jobs.json — do not assume this section describes the live file.
- **Cron API note**: the WebUI cronjob tool's write/read calls can hang
  (delivery_error 'unknown platform webui'). For a prompt change use the CLI
  FIRST — `hermes cron edit <job-id> --prompt '<full new prompt>'` — then read
  the prompt back out of `cron/jobs.json` to confirm it landed; it is far
  simpler than hand-editing the store. Hand-editing jobs.json (atomic
  tmp+rename, backup first, key is `id` not `job_id`, keep model/provider
  pins) is the fallback. Either route may still need `systemctl --user restart
  hermes-gateway-turbo-carnival` (needs user approval) before the scheduler
  serves the new prompt, so VERIFY on the next tick instead of assuming the
  edit took effect.

### Budgeting a long-running cron job's tool calls

`hermes cron create` exposes NO per-job timeout flag, so an agent-driven job inherits
the default tool-call budget, and any job whose work exceeds a single call gets that
call cut off. An agent that reads the cutoff as "the job failed" then reports a FALSE
failure every tick — and the work often completed anyway. This project has several such
jobs (the corpus tree walk, `sync_cadence`'s render+poll loop, `ensure`'s claim wait),
so when writing or editing one of their prompts:

- Launch the work with `terminal(background=True, notify=True)` and wait on it with the
  process tool; never run a multi-minute job in the foreground of a tick.
- Say IN THE PROMPT that a tool-call timeout is NOT a failure, and that before
  concluding anything the next tick must VERIFY (slot contents, `--verify-only`, a
  row's terminal status) rather than trusting the absence of output.
- Give the expected runtime, and give the slower FIRST run (a cold pass that copies or
  computes everything) separately from steady-state runs, so the agent can tell "still
  working" from "stuck".
- Prefer a script that exits non-zero on real failure and prints a one-line verdict, so
  the prompt keys on the exit code and the verdict instead of re-deriving health from
  raw output.

The guard costs one paragraph and it is the difference between a job you can trust and
one you learn to ignore.
