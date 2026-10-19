# Quality Assurance, Image Selection & Social Feedback Loop

## Goal
Automatically detect blurry images, select the best candidates, and close the loop by learning from Instagram engagement to continuously improve content quality and grow toward 1K followers.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    GENERATION PIPELINE                       │
│  ComfyUI → 5-step flux → ImageCandidate (step 5)            │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  PHASE 1: TECHNICAL QA                                      │
│  - Laplacian variance (blur detection)                      │
│  - Resolution check                                          │
│  - Contrast / exposure                                       │
│  └─→ Below threshold? → REJECT                              │
└──────────────────────┬──────────────────────────────────────┘
                       │ passed
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  PHASE 2: AUTO-SELECTION                                    │
│  - Rank by technical score                                   │
│  - Blend with pillar affinity score (from phase 3)           │
│  - Top-K → mark as winners → create photos → schedule posts │
└──────────────────────┬──────────────────────────────────────┘
                       │ posted to Instagram
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  PHASE 3: SOCIAL FEEDBACK LOOP                              │
│  - Fetch post insights (likes, comments, reach, saves)       │
│  - Compute engagement score per post                         │
│  - Feed back into:                                           │
│    ├─ Pillar weights (post more of what works)               │
│    ├─ Image style preferences (which aesthetics perform)     │
│    ├─ Caption tone optimization                              │
│    ├─ Posting time optimization                              │
│    └─ Prompt refinement (generate more of what resonates)    │
└─────────────────────────────────────────────────────────────┘
```

## Phase 1: Technical QA (same as before)

### 1.1 Enable image_processing gem
- **File:** `Gemfile` line 37 — uncomment `gem "image_processing", "~> 1.2"`
- **Run:** `bundle install`

### 1.2 Python blur detection script
- **File:** `scripts/assess_image_quality.py`
- OpenCV `cv2.Laplacian` variance (industry standard)
- Returns JSON: `{blur_score, width, height, contrast, brightness, passed, issues: []}`
- Threshold: `QA_BLUR_THRESHOLD` (default 100)
- Also checks: resolution < 512px, extreme over/under exposure

### 1.3 QualityAssessImage GLCommand
- **File:** `packs/pipeline/app/commands/quality_assess_image.rb`
- Calls Python script, stores results on candidate
- Returns `{score: 0-100, passed: bool, metrics: {}}`

### 1.4 Schema: quality columns on ImageCandidate
- `quality_score` (float, 0-100)
- `quality_metrics` (JSONB: blur_score, contrast, brightness, resolution)
- `engagement_score` (float, nullable — populated by Phase 3)

## Phase 2: Auto-Selection with Quality Ranking

### 2.1 AutoSelectWinners GLCommand
- **File:** `packs/pipeline/app/commands/auto_select_winners.rb`
- For each run, gather step-5 candidates with quality scores
- Compute composite score:
  ```
  composite = (technical_score * 0.4) + (pillar_affinity * 0.3) + (diversity_bonus * 0.3)
  ```
  - `technical_score`: from Phase 1 QA (normalized 0-100)
  - `pillar_affinity`: from Phase 3 feedback (how well this pillar performs historically)
  - `diversity_bonus`: penalty for repeating same pillar/style recently
- Sort by composite descending
- Top `AUTO_SELECT_TOP_K` (default 3) → `mark_as_winner!` → creates Photo records
- Non-winners left active as backup pool

### 2.2 ProcessJobResult integration
- **File:** `packs/comfyui/app/commands/process_job_result.rb`
- After creating final-step candidate, run `QualityAssessImage`
- Below threshold → `candidate.reject!`
- Above threshold → nothing (AutoSelectWinners handles grouping)

### 2.3 Update conversion cron
- **File:** `social-convert-photos.sh`
- Replace manual conversion with `AutoSelectWinners.call`

## Phase 3: Social Feedback Loop

### 3.1 Instagram Insights Collection

**New command:** `CollectPostInsights`
- **File:** `packs/scheduling/app/commands/collect_post_insights.rb`
- For each post published 24-48h ago, fetch:
  ```
  GET /{media_id}/insights?metric=likes,comments,reach,saved,shares
  ```
- Store on `Scheduling::Post` via new columns:
  - `likes_count` (integer)
  - `comments_count` (integer)
  - `reach` (integer)
  - `saved_count` (integer)
  - `engagement_rate` (float — computed: (likes+comments+saves)/reach)
  - `insights_updated_at` (timestamp)

### 3.2 Engagement Scoring

**New command:** `ComputeEngagementScores`
- **File:** `packs/content_strategy/app/commands/compute_engagement_scores.rb`
- Per-pillar rolling averages (last 14 days)
- Per-post engagement rate percentile
- Feed back into `ImageCandidate.engagement_score` for the photo that was posted
- Build "pillar performance index":
  ```ruby
  {
    "Fitness & Wellness" => { avg_engagement: 0.032, trend: :rising, posts: 3 },
    "Food & Cooking"     => { avg_engagement: 0.018, trend: :falling, posts: 2 },
    ...
  }
  ```

### 3.3 Strategy Adjustment

**Update the weekly strategy review cron** to use engagement data:

| Signal | Adjustment |
|--------|-----------|
| Pillar X has 2× engagement of pillar Y | Boost X's weight, reduce Y's |
| Posts at 9am outperform 3pm | Shift posting window |
| Captions with questions get more comments | Adjust caption config to favor questions |
| Certain image styles (close-up, outdoor, etc.) perform better | Bias future prompts toward winning styles |

### 3.4 Prompt Feedback Loop

The most powerful feedback: feeding engagement data back into prompt generation.

**New concept:** `PromptTemplate` with performance history
- Each ComfyUI prompt template tracks its "children's" average engagement
- When creating new runs, prefer templates with higher historical engagement
- Periodically generate variant prompts (A/B test new styles)

```
Prompt "Sarah yoga studio" → avg engagement 0.031 ✅
Prompt "Sarah beach sunset" → avg engagement 0.019 ⚠️
→ Generate 2× more yoga prompts, reduce beach prompts
```

## Schema Changes Summary

```ruby
# ImageCandidate
add_column :image_candidates, :quality_score, :float
add_column :image_candidates, :quality_metrics, :jsonb, default: {}
add_column :image_candidates, :engagement_score, :float

# Scheduling::Post
add_column :scheduling_posts, :likes_count, :integer
add_column :scheduling_posts, :comments_count, :integer
add_column :scheduling_posts, :reach, :integer
add_column :scheduling_posts, :saved_count, :integer
add_column :scheduling_posts, :engagement_rate, :float
add_column :scheduling_posts, :insights_updated_at, :datetime
```

## Files to Create/Modify

| Phase | File | Action |
|-------|------|--------|
| 1 | `Gemfile` | Uncomment `image_processing` |
| 1 | `scripts/assess_image_quality.py` | **NEW** |
| 1 | `packs/pipeline/app/commands/quality_assess_image.rb` | **NEW** |
| 1 | `db/migrate/*_add_quality_to_candidates.rb` | **NEW** |
| 2 | `packs/pipeline/app/commands/auto_select_winners.rb` | **NEW** |
| 2 | `packs/comfyui/app/commands/process_job_result.rb` | Modify |
| 2 | `social-convert-photos.sh` | Replace logic |
| 3 | `packs/scheduling/app/commands/collect_post_insights.rb` | **NEW** |
| 3 | `packs/content_strategy/app/commands/compute_engagement_scores.rb` | **NEW** |
| 3 | `db/migrate/*_add_insights_to_posts.rb` | **NEW** |
| 3 | `social-strategy-review` cron prompt | Update to use engagement data |

## Cron Job Updates

| Job | Change |
|-----|--------|
| Content Gap (daily 2am) | Add `auto_select_winners` call after conversion |
| Follower Tracker (daily 8am) | Add insight collection for posts 24h+ old |
| Strategy Review (Sun 7am) | Read engagement scores, adjust pillar weights + prompts |

## Risks

| Risk | Mitigation |
|------|-----------|
| Instagram API rate limits | Batch insights, cache results, respect 200 calls/hour limit |
| Cold start (no engagement data) | Default to equal pillar weights until 7+ posts have data |
| Feedback loop narrows diversity | Diversity bonus (30% of composite score) prevents monoculture |
| Engagement ≠ follower growth | Track both independently; high engagement on wrong audience = noise |

## Implementation Order

1. **Phase 1** (1-2 hours) — Technical QA: blur detection + auto-rejection
2. **Phase 2** (1 hour) — Auto-selection: ranking + winner marking
3. **Phase 3** (2-3 hours) — Feedback loop: insights collection + strategy adjustment

Phase 1 & 2 can ship independently. Phase 3 needs Phase 1+2 deployed and 7+ days of post data before it becomes useful.
