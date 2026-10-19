# Quality Assurance & Image Selection Implementation Plan

## Goal
Automatically detect and reject blurry/low-quality AI-generated images, and auto-select the best images from each pipeline run for Instagram posting — no human voting required.

## Current Context

**Problem:** Raw step-1 Flux outputs were posted (blurry). Even step-5 upscaled outputs vary in quality. The existing ELO-based A/B voting system requires manual human input — unsustainable for autonomous posting.

**What exists:**
- `ImageCandidate` model with `elo_score`, `vote_count`, `winner`, `status`, `failure_count`
- `RecordVote` command — manual ELO voting (K=32)
- `PollJobStatus` — auto-rejects branches after 3 failures
- `mark_as_winner!` — creates `ContentPillars::Photo` on winner selection
- `image_processing` gem commented out in Gemfile

## Proposed Approach

Add a lightweight blur-detection step after image generation, then auto-rank candidates by quality and select winners without human intervention. Use OpenCV (already available in ComfyUI's venv) for reliable Laplacian variance blur detection.

### Architecture

```
Image Generated (step 5)
        │
        ▼
┌──────────────────┐
│ QualityAssess    │ ← Python script (OpenCV Laplacian variance)
│  - blur score    │
│  - resolution    │
│  - contrast      │
└──────┬───────────┘
       │
  score < threshold? ──→ auto-reject
       │
  score >= threshold
       │
       ▼
┌──────────────────┐
│ AutoSelectWinner │ ← Ruby command
│  - rank by score │
│  - top-N wins    │
│  - create photo  │
└──────────────────┘
```

## Step-by-Step Plan

### 1. Enable image_processing gem
- **File:** `Gemfile` line 37 — uncomment `gem "image_processing", "~> 1.2"`
- **File:** `Dockerfile` (if exists) — ensure libvips or ImageMagick available
- **Run:** `bundle install`
- **Validation:** `bundle list | grep image_processing`

### 2. Create Python blur detection script
- **File:** `scripts/assess_image_quality.py`
- Uses OpenCV's `cv2.Laplacian` for variance-of-Laplacian (industry standard)
- Returns JSON: `{blur_score, width, height, contrast, passed}`
- Threshold: Laplacian variance < 100 = blurry (tunable via env var)
- **Validation:** Run against known blurry and sharp images

### 3. Create QualityAssessImage GLCommand
- **File:** `packs/pipeline/app/commands/quality_assess_image.rb`
- Calls Python script via `Open3.capture3`
- Stores quality metadata on `ImageCandidate` (new JSONB column)
- Returns `{score, passed, metadata}`
- **Validation:** Unit spec with mocked script output

### 4. Add quality_score column to ImageCandidate
- **Migration:** add `quality_score` (float) and `quality_metadata` (JSONB) to `image_candidates`
- Backfill nil for existing candidates
- **Validation:** `ImageCandidate.last.quality_score` works

### 5. Create AutoSelectWinners GLCommand
- **File:** `packs/pipeline/app/commands/auto_select_winners.rb`
- For a given run: gather all step-5 candidates with quality scores
- Sort by quality_score descending
- Top `TOP_K` (default 3) get marked as winners
- Winners get `mark_as_winner!` → creates Photo records
- Non-winners can be rejected or left active for future
- **Validation:** Spec with test candidates at various quality levels

### 6. Update ProcessJobResult to trigger QA
- **File:** `packs/comfyui/app/commands/process_job_result.rb`
- After creating `ImageCandidate`, if it's the final step (step 5), call `QualityAssessImage`
- If quality check fails, auto-reject the candidate (`candidate.reject!`)
- **Validation:** Integration spec

### 7. Update conversion cron to use AutoSelectWinners
- **File:** `~/.hermes/profiles/turbo-carnival/scripts/social-convert-photos.sh`
- Replace manual conversion with `AutoSelectWinners.call(run: run)`
- This auto-ranks, picks winners, and creates photos in one step
- **Validation:** Run manually, verify only high-quality images become photos

### 8. Add configuration env vars
- `QA_BLUR_THRESHOLD` — Laplacian variance minimum (default: 100)
- `QA_MIN_RESOLUTION` — minimum width×height (default: 512×512)
- `AUTO_SELECT_TOP_K` — how many winners per run (default: 3)
- `AUTO_SELECT_ENABLED` — feature flag (default: true)

### 9. Add auto-rejection of low-quality candidates
- **File:** `packs/comfyui/app/commands/process_job_result.rb`
- If QA score < threshold on final step: `candidate.reject!` + log
- This prevents blurry images from reaching the selection pool

## Files to Change

| File | Action |
|------|--------|
| `Gemfile` | Uncomment `image_processing` |
| `scripts/assess_image_quality.py` | **NEW** — blur detection |
| `packs/pipeline/app/commands/quality_assess_image.rb` | **NEW** — QA command |
| `packs/pipeline/app/commands/auto_select_winners.rb` | **NEW** — auto-selection |
| `packs/comfyui/app/commands/process_job_result.rb` | Modify — trigger QA on step 5 |
| `db/migrate/*_add_quality_to_image_candidates.rb` | **NEW** — schema |
| `~/.hermes/profiles/turbo-carnival/scripts/social-convert-photos.sh` | Replace manual conversion |
| `packs/pipeline/app/models/image_candidate.rb` | Add `quality_score` validation |

## Tests

- `spec/commands/quality_assess_image_spec.rb` — mock Python output, test thresholds
- `spec/commands/auto_select_winners_spec.rb` — verify top-K selection logic
- `spec/commands/process_job_result_spec.rb` — verify QA is triggered on final step
- `scripts/test_blur_detection.py` — manual test against sample images

## Risks & Tradeoffs

| Risk | Mitigation |
|------|-----------|
| OpenCV not available in production | Fall back to MiniMagick edge-detection if Python fails |
| Laplacian threshold too strict | Configurable via `QA_BLUR_THRESHOLD` env var |
| Good images falsely rejected | Log all QA scores; review rejected candidates before hard-delete |
| Python dependency management | Use ComfyUI's existing venv (`/mnt/fscache/essdee/ComfyUI/.venv/bin/python`) |

## Open Questions

1. **Threshold tuning:** What Laplacian variance value separates "good" from "blurry" for Flux-generated images? Start at 100, tune based on real data.
2. **Existing candidates:** Should we re-assess already-posted candidates? Probably not — the 4 blurry ones are already live. Focus on future.
3. **Non-winner handling:** After selecting top-K winners, what happens to the rest? Options: leave active for future runs, reject to free resources, or keep as backup.
