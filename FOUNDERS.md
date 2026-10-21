# FOUNDERS — pillar index

Each pillar: **Lock / Enforcement / Red line**. Status-tagged:
`#harness/status/locked` · `in-review` · `rebuilding`. Keep it living.

The thesis itself — problem / user / value, the founder's red lines
("We will NOT"), and the five locked rails — lives in `THESIS.md` (CURRENT).
This file indexes the repo's pillars and what holds each one.

| Pillar | Lock | Enforcement | Red line | Status |
|---|---|---|---|---|
| The legal floor | PRD 0007 §1 · `Growth::PersonaAgeGate` (band + tier) · the synthetic mark on the served bytes (`GeneratePublicPhotoUrl`) | the floor gates run on the bytes and fail closed · `bin/tc_ops.py` probes (age holds, unmarked provenance) | never publish a minor read, a real-person likeness, or an unmarked asset | `#harness/status/locked` |
| Verifiable done | `bin/verify` (bin/lint → brakeman → bundler-audit → packwerk → rspec) · the `bin/rspec` verdict contract (byte-identical to the template) | the CI `verify` job requires the `TESTS OK` line, not just exit 0 · `bin/test-agent-signal` (12 contract checks) | a 0-example run is never a pass; a gate that cannot run is a failure, not a pass | `#harness/status/locked` |
| Agent governance | `AGENTS.md` hub → board (project 5) + labels in `config/autonomous/pipeline.yml` → the PR gate (`.github/pull_request_template.md`) | the CI gates + read-back of board Status/labels · the `pr-conventions-gate` skill | an agent never sets `approved`; a failed create is never reported as a no-op | `#harness/status/locked` |
| Bounded contexts + house style | the packwerk boundaries (declared + individually baselined) · rubocop-rails-omakase + erb_lint behind `bin/lint` (repo-local configs) | `bin/packwerk check` = 0 violations, in `bin/verify` and CI · `bin/lint` in the same gate | no cross-pack reference beyond the declared dependencies | `#harness/status/locked` |
| The boring stack | Rails 8 + pg + Puma + importmap + Turbo/Stimulus · the head `meta turbo-refresh-method morph` trigger | the layout spec asserts the head `meta` (the mechanism, never the marker) · CI | no new work on `solid_*` (Sidekiq is the substrate) | `#harness/status/rebuilding` |
| The experiment lane | `docs/experiment-backlog.md` (pre-registration + verdicts) · the harness's leaf-diff assertion | one variable per experiment, pre-registered before code · removing an experiment folder must not change production behaviour | an incomplete render set is never presented as a smaller N | `#harness/status/locked` |
| Thesis + content pillars | the `THESIS.md` rails (identity anchor, attribution spine, safety gates, decision ledger, reflection) · the `AGENTS.md` authority ladder | `Growth::PersonaEvolution` (single-step delta, pre-registered gate, automatic revert) · the `Growth::Decision` ledger | class 4 (identity: Sarah, 18) moves only on a founder ruling; a red line needs a founder source | `#harness/status/locked` |
| Measurements + observability | the PRD 0007 A1/B3 advisory measurements (`Growth::NsfwGate`, `Growth::RealismGate` — no `safe` member) · the Sentry initialiser + DSN in encrypted credentials | scores persisted on the asset rows (nsfw / aesthetic / sharpness) · `Sentry::Metrics` emits the charter gauges | a measurement is never re-read as a veto; an agent safety preference is never promoted into a founder red line | `#harness/status/locked` |
| Render pipeline discipline | `bin/comfyui_harness.sh` under the file-based GPU claim · the queue-first lifecycle | the `bin/tc_ops.py` probes (false-idle leak, own-queue flood, unclaimed ComfyUI) | never launch ComfyUI unclaimed; never SIGTERM a live queue | `#harness/status/locked` |

> `#harness/status/rebuilding` on the boring stack: the HAML transition
> (#84) and the Sidekiq substrate swap retiring `solid_*` (#85) are open —
> the stack is conformant today and mid-transition, so it is tagged
> rebuilding rather than locked.
