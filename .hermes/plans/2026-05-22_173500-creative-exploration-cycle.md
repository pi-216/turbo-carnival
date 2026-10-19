# Creative Exploration Cycle — Test Pillars & Concept Discovery

## Problem
Without exploration, the feedback loop optimizes within known pillars — a local maximum. Sarah might max out at 300 followers because the system never discovers that "Book Reviews" or "Thrift Hauls" or "Morning Routines" would resonate better than "Fitness & Wellness."

## Solution: Monthly Creative Sprint

Every 4 weeks, create a temporary **test pillar** with a new concept. Run it for a limited batch. Measure engagement. Promote winners, retire losers.

```
Week 1-3: Normal operation (proven pillars)
Week 4:   Creative sprint (test pillar)
          ├─ Generate 5-10 images for new concept
          ├─ Post 3-5 times that week
          ├─ Measure engagement vs baseline
          └─ Decision: promote to permanent or retire
```

## Test Pillar Lifecycle

### 1. Generation (Week 3, prep for Week 4)

**Source of test concepts:**
- **Competitor analysis:** What's working for similar accounts?
- **Trend exploration:** Seasonal, viral formats, emerging aesthetics
- **Content gaps:** What formats/pillars are we missing entirely?
- **Random exploration:** Wildcard concepts (10% of tests)
- **AI suggestion:** Ask LLM "what would grow a young woman's Instagram in 2026?"

Each test gets:
- A unique pillar name (e.g., `test-jun-2026-thrift-hauls`)
- 5-10 prompt templates
- A temporary weight (5% of posting schedule for test week)
- An engagement target (must outperform bottom quartile of proven pillars)

### 2. Evaluation (Week 4-5)

After test week, compute:
```
test_engagement_rate = avg(likes + comments + saves) / avg(reach) for test posts
baseline_rate        = avg engagement rate across all proven pillars (last 28 days)
promotion_threshold  = baseline_rate * 1.2  # Must be 20% better
```

**Decision matrix:**

| Outcome | Action |
|---------|--------|
| `test_rate > baseline * 1.5` | **Promote to permanent** — full weight, regular rotation |
| `test_rate > baseline * 1.2` | **Extend** — run another 2 weeks for more data |
| `test_rate > baseline * 0.8` | **Archive** — interesting but underpowered, retry later |
| `test_rate < baseline * 0.8` | **Retire** — delete pillar, free resources |

### 3. Promotion (Ongoing)

When a test pillar promotes to permanent:
- Create real `ContentPillar` record with initial weight of 8%
- Redistribute other pillar weights (reduce equally from all)
- Generate 20+ images for the new pillar
- Begin regular rotation

Old pillars that consistently underperform get weight-reduced or archived (but never deleted — historical posts stay).

## Creative Sprint Schema

### New Models

```ruby
# Test pillar tracking
create_table :creative_tests do |t|
  t.references :persona
  t.string :name, null: false           # e.g., "test-jun-2026-thrift-hauls"
  t.string :concept, null: false        # Short description of the idea
  t.string :source                      # "competitor", "trend", "random", "ai-suggestion"
  t.string :status, default: "active"   # active, extended, promoted, retired
  t.date :start_date
  t.date :end_date
  t.integer :posts_count, default: 0
  t.float :engagement_rate
  t.float :baseline_rate                # Comparison rate at time of test
  t.jsonb :prompt_templates, default: []
  t.jsonb :results, default: {}         # Raw insights data
  t.timestamps
end

# Track which image candidates belong to test pillars
add_column :image_candidates, :creative_test_id, :bigint, null: true
```

### New Commands

| Command | File | Purpose |
|---------|------|---------|
| `CreativeTest::GenerateConcepts` | `packs/content_strategy/app/commands/creative_test/generate_concepts.rb` | AI-suggests 5 test concepts based on gaps + trends |
| `CreativeTest::CreateTestRun` | `packs/content_strategy/app/commands/creative_test/create_test_run.rb` | Creates temporary pillar + pipeline run with test prompts |
| `CreativeTest::EvaluateResults` | `packs/content_strategy/app/commands/creative_test/evaluate_results.rb` | Computes engagement vs baseline, makes promote/retire decision |

### New Cron Job

| When | What |
|------|------|
| Monthly, 1st Sunday | **Creative Sprint** — evaluate last month's test, generate new test concepts, create test pillar for this month |

## Creative Schedule (2026)

| Month | Test Pillar Ideas |
|-------|-------------------|
| June | Thrift hauls / vintage fashion finds |
| July | Morning routines / daily vlog aesthetic |
| August | Book reviews / cozy reading nook |
| September | Back-to-school / study aesthetic |
| October | Autumn fashion layering / cozy vibes |
| November | Gratitude journaling / mental health |
| December | Holiday gift guides / festive decor |

Each month, 3-5 concepts are generated (AI + manual), the top 1-2 are selected for testing.

## Integration with Feedback Loop

The creative sprint feeds into the existing Phase 3 feedback loop:

```
Monthly: Creative Sprint evaluates test pillar
           │
           ├─ Promoted? → Add to proven pillar rotation
           │               ↓
           │         Weekly: Strategy review adjusts ALL weights
           │                 (including newly promoted pillar)
           │
           └─ Retired? → Insights logged for future reference
                          (maybe "book reviews" didn't work in June
                           but might work in September)
```

## Risks & Safeguards

| Risk | Safeguard |
|------|-----------|
| Test pillar cannibalizes proven content | Max 5% of weekly posts during test |
| Bad test damages brand | All test images still go through QA (blur check) |
| Too many pillars dilutes focus | Hard cap: 15 active pillars (10 proven + 5 seasonal + 2 test) |
| AI generates inappropriate test concepts | Human-curated allowlist + content safety check |
| Promotion based on noise (small sample) | Minimum 5 posts + 7 days before evaluation |

## Implementation Order

1. **Schema** — `creative_tests` table + `creative_test_id` on candidates
2. **GenerateConcepts** command — AI-powered concept brainstorming
3. **CreateTestRun** command — scaffold test with prompts + pipeline
4. **EvaluateResults** command — promotion/retirement logic
5. **Monthly cron job** — ties it all together on a schedule
6. **Strategy review update** — includes test results in weekly analysis

~3 hours to implement. Can ship independently of the QA/Feedback Loop phases.
