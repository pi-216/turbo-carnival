# Universal Persona Management Platform - Integration Report

**Date:** 2025-12-01  
**Status:** Analysis Complete  
**Repositories Analyzed:**
- FLENwheel (Persona LoRA Training)
- turbo-carnival (Image Generation Pipeline)
- fluffy-train (Content Planning & Instagram Posting)

---

## Executive Summary

I've conducted an in-depth analysis of all three repositories. Here's my honest assessment:

**Good News:**
- **turbo-carnival** and **fluffy-train** are highly compatible - both use Rails 8, Packwerk, PostgreSQL, and similar architectural patterns
- The existing merge spec in `openspec/changes/merge-fluffy-train/` provides an excellent foundation
- No database schema conflicts between the three systems
- All three systems address different, complementary parts of the persona content pipeline

**Challenges:**
- **FLENwheel is fundamentally different** - it's a Python-based ML/AI training system for creating character LoRAs, while the others are Rails web applications
- FLENwheel operates at a *different layer* (training personas) vs managing content for existing personas
- Integration requires careful thought about which features belong together

**Recommendation:** **Phased Integration with Two Products**

---

## I. Architecture Analysis

### Current State

```
┌─────────────────────────────────────────────────────────────────┐
│                    Three Separate Systems                        │
└─────────────────────────────────────────────────────────────────┘

┌───────────────────────┐   ┌───────────────────────┐   ┌─────────────────────────┐
│   FLENwheel (Python)  │   │ turbo-carnival (Rails)│   │ fluffy-train (Rails)    │
│                       │   │                       │   │                         │
│ • Qwen-Image-Edit     │   │ • ComfyUI Integration │   │ • Persona Management    │
│ • FLUX LoRA Training  │   │ • Pipeline Execution  │   │ • Content Pillars       │
│ • Dual Flywheel       │   │ • Voting/ELO Ranking  │   │ • AI Content Planning   │
│ • Character Training  │   │ • Approval Gates      │   │ • Clustering            │
│ • Python Scripts      │   │ • Image Tree          │   │ • Instagram Posting     │
│ • Local 4090 GPU      │   │ • Web UI              │   │ • Content Strategy      │
│                       │   │                       │   │ • TUI (no web)          │
│ No Database           │   │ PostgreSQL            │   │ PostgreSQL              │
│ Filesystem-based      │   │ ImageCandidate model  │   │ Photo model             │
└───────────────────────┘   └───────────────────────┘   └─────────────────────────┘
         ↓                            ↓                              ↓
    Training                     Generation                      Publishing
    Phase                        Phase                           Phase
```

### Key Insights

#### 1. **Two Distinct Layers**

**Layer 1: Persona Creation (FLENwheel)**
- **Frequency:** Once per persona (or when updating persona appearance)
- **User:** Advanced/technical user
- **Output:** Trained LoRA files, character models
- **Technology:** Python, PyTorch, Diffusers, PEFT
- **Storage:** Filesystem (source images, generated images, trained models)

**Layer 2: Content Production (turbo-carnival + fluffy-train)**
- **Frequency:** Daily/weekly content creation
- **User:** Content creator
- **Output:** Instagram posts
- **Technology:** Rails, PostgreSQL, ActiveStorage
- **Storage:** Database + cloud storage

#### 2. **Natural Integration Points**

```
FLENwheel (Standalone)
    ↓ (exports LoRA files to directory)
    
turbo-carnival + fluffy-train (Merged)
    ↓ (uses LoRA files in ComfyUI workflows)
    ↓ (creates ImageCandidates)
    ↓ (schedules to Instagram)
```

#### 3. **Data Model Compatibility**

**COMPATIBLE (turbo-carnival ↔ fluffy-train):**
- ✅ Both use Packwerk with similar pack structure
- ✅ Both use PostgreSQL with no schema conflicts
- ✅ Both use Rails 8.0 with ViewComponents
- ✅ Both use GLCommand pattern
- ✅ Similar testing frameworks (RSpec, FactoryBot)
- ✅ Complementary features (generation + posting)

**INCOMPATIBLE (FLENwheel ↔ Rails apps):**
- ❌ Different languages (Python vs Ruby)
- ❌ Different purposes (training vs production)
- ❌ Different users (ML engineer vs content creator)
- ❌ Different infrastructure (local GPU vs web server)
- ❌ Different data models (filesystem vs database)

---

## II. Integration Strategy

### Recommended Approach: **Two Products, One Workflow**

#### Product 1: **FLENwheel** (Standalone Python Tool)
**Purpose:** Character LoRA Training System  
**Users:** Technical users, ML engineers  
**When:** Initial persona creation, periodic retraining

**Scope:**
- ✅ Keep as standalone Python application
- ✅ Focused on LoRA training workflow
- ✅ Outputs LoRA files to shared directory
- ✅ No database, filesystem-based
- ✅ Manual workflow with human review gates

**Improvements:**
- Add export metadata (JSON file with LoRA info)
- Standardized output directory structure
- Documentation for integration with turbo-carnival

#### Product 2: **Unified Content Platform** (turbo-carnival + fluffy-train)
**Purpose:** Persona Content Creation & Publishing  
**Users:** Content creators, social media managers  
**When:** Daily content production

**Scope:**
- ✅ Merge fluffy-train INTO turbo-carnival
- ✅ Single Rails application
- ✅ Single database
- ✅ Unified web interface
- ✅ End-to-end workflow: gap analysis → generation → posting

**New Features from Integration:**
- LoRA management UI (register FLENwheel outputs)
- Link personas to LoRA files
- ComfyUI workflows use persona-specific LoRAs

---

## III. Detailed Integration Plan

### Phase 1: Merge turbo-carnival + fluffy-train (5 weeks)

**Foundation (Week 1)**
```
Day 1-2: Copy Personas pack from fluffy-train
         - Personas table
         - PersonasController
         - Web UI for persona CRUD

Day 3-4: Copy Content Pillars pack
         - content_pillars table
         - pillar_cluster_assignments
         - Gap analysis display
         - Pillar management UI

Day 5:   Testing and validation
```

**Content Management (Week 2)**
```
Day 1-3: Adapt Clustering pack
         - Create cluster_candidates join table
         - Support both Photo AND ImageCandidate
         - Polymorphic cluster.images method
         - Cluster management UI

Day 4:   Pipeline linking
         - Add persona_id, cluster_id to pipelines table
         - Auto-link winner to cluster callback
         - Test winner → cluster flow

Day 5:   Testing and validation
```

**AI Services (Week 3)**
```
Day 1:   Copy AI libraries
         - lib/ai/gemini_client.rb
         - lib/ai/content_prompt_generator.rb
         - CreateContentPipeline service
         - "Generate Content" button in UI

Day 2:   Caption Generation pack
         - Copy packs/caption_generations/
         - Adapt for ImageCandidate
         - Test AI caption generation

Day 3:   Hashtag Generation pack
         - Copy packs/hashtag_generations/
         - Integrate with captions
         - Test hashtag suggestions

Day 4-5: Testing and validation
```

**Strategy & Scheduling (Week 4)**
```
Day 1-2: Content Strategy pack
         - Copy packs/content_strategy/
         - Adapt selector for ImageCandidate
         - Preview next post UI
         - Test strategy selection

Day 3:   Scheduling pack
         - Copy packs/scheduling/
         - Instagram API integration
         - Scheduling interface
         - Test Instagram posting

Day 4-5: Testing and validation
```

**UI & Polish (Week 5)**
```
Day 1-3: Unified Dashboard
         - Persona show page with all features
         - Gap analysis → Generate → Vote → Schedule
         - Active pipelines monitoring
         - Content library view
         - Upcoming posts calendar

Day 4-5: Documentation & Polish
         - Update README
         - Integration tests
         - Production deployment prep
         - Copy fluffy-train OpenSpecs
```

**Detailed Spec Reference:** `openspec/changes/merge-fluffy-train/proposal.md`

---

### Phase 2: LoRA Integration Bridge (2 weeks)

**Purpose:** Connect FLENwheel outputs to unified platform

**LoRA Management (Week 1)**
```
Create new pack: packs/lora_management/

Models:
- LoraModel
  - name (string)
  - version (string)
  - file_path (string) - path to .safetensors file
  - metadata (jsonb) - training info from FLENwheel
  - persona_id (foreign key)
  - model_type (enum: character, style, concept)
  - created_at, updated_at

- PersonaLoraMapping
  - persona_id
  - lora_model_id
  - weight (float) - LoRA strength (0.0-1.0)
  - primary (boolean)

UI:
- LoRA library view
- Import FLENwheel outputs
- Associate LoRAs with personas
- Test LoRA in ComfyUI
```

**ComfyUI Integration (Week 2)**
```
Extend BuildJobPayload:
- Detect persona_id in pipeline
- Load associated LoRA files
- Inject LoRA nodes into workflow JSON
- Template variable: {{lora_path}}, {{lora_weight}}

Example workflow template:
{
  "lora_loader": {
    "inputs": {
      "lora_name": "{{lora_path}}",
      "strength_model": {{lora_weight}},
      "model": ["checkpoint_loader", 0]
    },
    "class_type": "LoraLoader"
  }
}

UI:
- Persona settings: LoRA selection
- Pipeline creation: auto-include persona LoRAs
- Test generation with character LoRAs
```

---

## IV. Unified Data Model

### Core Entities

```ruby
# Unified Platform Schema

# Persona (from fluffy-train)
create_table "personas" do |t|
  t.string "name", null: false
  t.jsonb "caption_config", default: {}
  t.jsonb "hashtag_strategy", default: {}
  # NEW for LoRA integration
  t.string "default_lora_id"  # Primary LoRA for this persona
  t.jsonb "generation_settings", default: {}  # Default ComfyUI settings
end

# ContentPillar (from fluffy-train)
create_table "content_pillars" do |t|
  t.bigint "persona_id", null: false
  t.string "name", null: false
  t.decimal "weight", precision: 5, scale: 2
  t.date "start_date"
  t.date "end_date"
  t.jsonb "guidelines", default: {}
end

# Cluster (from fluffy-train, adapted)
create_table "clusters" do |t|
  t.bigint "persona_id", null: false
  t.string "name"
  t.text "ai_prompt"
  t.integer "photos_count", default: 0
end

# ClusterCandidate (NEW - join table)
create_table "cluster_candidates" do |t|
  t.bigint "cluster_id", null: false
  t.bigint "image_candidate_id", null: false
  t.jsonb "metadata", default: {}  # ELO, pipeline info
  t.integer "display_order"
end

# Pipeline (from turbo-carnival, extended)
create_table "pipelines" do |t|
  t.string "name", null: false
  t.text "description"
  # NEW for persona integration
  t.bigint "persona_id"  # Optional: for content pipelines
  t.bigint "cluster_id"  # Optional: target cluster for auto-linking
end

# PipelineRun (from turbo-carnival)
create_table "pipeline_runs" do |t|
  t.bigint "pipeline_id", null: false
  t.string "name"
  t.jsonb "variables", default: {}
  t.string "status", default: "pending"
end

# ImageCandidate (from turbo-carnival)
create_table "image_candidates" do |t|
  t.bigint "pipeline_step_id", null: false
  t.bigint "pipeline_run_id"
  t.bigint "parent_id"  # Tree structure
  t.integer "elo_score", default: 1000
  t.string "status", default: "active"
  t.boolean "winner", default: false
end

# Photo (from fluffy-train, legacy support)
create_table "photos" do |t|
  t.bigint "persona_id", null: false
  t.bigint "cluster_id"
  t.string "path", null: false
  t.vector "embedding", limit: 512
end

# SchedulingPost (from fluffy-train)
create_table "scheduling_posts" do |t|
  t.bigint "photo_id"  # Legacy
  t.bigint "image_candidate_id"  # NEW: alternative to photo_id
  t.bigint "persona_id", null: false
  t.bigint "cluster_id"
  t.text "caption"
  t.jsonb "hashtags", default: []
  t.string "status", default: "draft"
  t.datetime "scheduled_at"
  t.datetime "posted_at"
end

# LoraModel (NEW - Phase 2)
create_table "lora_models" do |t|
  t.string "name", null: false
  t.string "version"
  t.string "file_path", null: false  # /path/to/loras/sarah_v3.safetensors
  t.jsonb "metadata", default: {}  # FLENwheel training info
  t.bigint "persona_id"  # Optional: character LoRAs linked to persona
  t.string "model_type"  # character, style, concept
end

# PersonaLoraMapping (NEW - Phase 2)
create_table "persona_lora_mappings" do |t|
  t.bigint "persona_id", null: false
  t.bigint "lora_model_id", null: false
  t.float "weight", default: 1.0  # 0.0 - 1.0
  t.boolean "primary", default: false
end
```

---

## V. Feature Interaction Matrix

### Single Persona Table ✅

**Problem Solved:** One authoritative source for persona identity

| Feature | Interaction | Notes |
|---------|------------|-------|
| **FLENwheel** | Exports LoRA → metadata includes persona name | Manual link to persona record |
| **Content Pillars** | `belongs_to :persona` | Strategic themes per persona |
| **Pipelines** | `belongs_to :persona` (optional) | Content pipelines tagged to persona |
| **Clusters** | `belongs_to :persona` | Content library organized by persona |
| **Scheduling** | `belongs_to :persona` | Posts attributed to persona |
| **LoRA Models** | `belongs_to :persona` (optional) | Character LoRAs linked to persona |

**Benefits:**
- Single source of truth
- Easy to query: "Show me everything for Sarah"
- Consistent persona metadata (caption style, hashtag strategy)
- No sync issues

---

### Workflow Integration

#### Scenario 1: **Create New Persona** (Full Lifecycle)

```
Step 1: FLENwheel (Python, standalone)
└─ Gather 10-20 source photos
└─ Run dual flywheel training
└─ Export LoRA: /loras/sarah_v1.safetensors
└─ Export metadata: /loras/sarah_v1.json

Step 2: Unified Platform (Web UI)
└─ Create Persona record (name: "Sarah")
└─ Import LoRA file (UI uploads sarah_v1.safetensors)
└─ System creates LoraModel record, links to persona
└─ Define Content Pillars (e.g., "Fitness 30%", "Travel 40%")

Step 3: Content Generation
└─ Gap analysis shows "Fitness" pillar is low
└─ Click "Generate Content" → AI creates prompt
└─ System creates Pipeline with persona_id
└─ BuildJobPayload injects Sarah's LoRA into ComfyUI workflow
└─ Pipeline runs → generates candidates
└─ User votes → winner auto-linked to cluster

Step 4: Publishing
└─ Content Strategy selects from cluster
└─ AI generates caption using persona style
└─ Schedule to Instagram
└─ Post published
```

#### Scenario 2: **Daily Content Creation** (Without LoRA Retraining)

```
User opens Persona Dashboard for "Sarah"
├─ Sees gap analysis: "Travel" pillar critical (0 images)
├─ Clicks "Generate Content"
│   └─ AI suggests: "Hiking mountain trail, sunrise, backpack"
│   └─ Creates cluster "Mountain Sunrise Hike"
│   └─ Creates pipeline run (auto-uses Sarah's LoRA)
│   └─ Redirects to voting interface
├─ User votes on candidates
├─ Approves gates
├─ Run completes → winner auto-linked to cluster
├─ Gap analysis updates: "Travel" pillar now ready
├─ Click "Schedule Post"
│   └─ Content Strategy selects optimal image
│   └─ AI generates caption
│   └─ Schedules for tomorrow 7am
└─ Done - all in one UI, 5-minute workflow
```

#### Scenario 3: **Update Persona Appearance** (LoRA Retraining)

```
Step 1: FLENwheel (when persona's look changes)
└─ Add new source photos (haircut, new style)
└─ Retrain LoRA → sarah_v2.safetensors
└─ Export to loras directory

Step 2: Unified Platform
└─ Import new LoRA version
└─ System creates LoraModel record (version: v2)
└─ Update PersonaLoraMapping to use v2 as primary
└─ Future pipelines automatically use new LoRA
└─ Old content remains linked to v1 (historical)
```

---

## VI. Risk Analysis & Mitigation

### Risk 1: **Complexity of Merging Two Rails Apps**
**Likelihood:** Medium  
**Impact:** High  
**Mitigation:**
- ✅ Both apps use Packwerk → pack-by-pack migration is clean
- ✅ No schema conflicts (verified)
- ✅ Existing merge spec provides detailed roadmap
- ✅ Can test each pack independently
- ✅ Keep fluffy-train running in parallel during migration

### Risk 2: **FLENwheel Integration Overhead**
**Likelihood:** Low  
**Impact:** Medium  
**Mitigation:**
- ✅ Keep FLENwheel standalone (right decision)
- ✅ Simple file-based integration (export LoRA files)
- ✅ Metadata JSON for programmatic import
- ✅ No real-time coupling required

### Risk 3: **Feature Regression**
**Likelihood:** Medium  
**Impact:** High  
**Mitigation:**
- ✅ Pack-by-pack testing after each migration
- ✅ Comprehensive RSpec test suite from both apps
- ✅ Integration tests for new connections
- ✅ Manual validation checklist

### Risk 4: **User Experience Consistency**
**Likelihood:** Low  
**Impact:** Medium  
**Mitigation:**
- ✅ Both apps use Tailwind CSS v4
- ✅ Both apps use ViewComponents
- ✅ Similar dark theme design language
- ✅ Unified dashboard brings everything together

### Risk 5: **Instagram API Changes**
**Likelihood:** Low  
**Impact:** High  
**Mitigation:**
- ✅ fluffy-train has working Instagram integration
- ✅ Well-tested scheduling pack
- ✅ Error handling and retry logic already implemented
- ✅ Documentation for credential setup

---

## VII. Migration Roadmap

### Phase 1: Core Integration (5 weeks)
**Goal:** Merge fluffy-train into turbo-carnival

**Deliverables:**
- ✅ Single Rails application
- ✅ Unified web interface
- ✅ Personas + Content Pillars
- ✅ Clusters (Photos + ImageCandidates)
- ✅ AI content generation
- ✅ Instagram posting
- ✅ Auto-linking (pipeline → cluster)

**Success Criteria:**
- All fluffy-train packs migrated
- All tests passing
- No packwerk violations
- End-to-end workflow functional
- Performance acceptable

**Reference:** `openspec/changes/merge-fluffy-train/proposal.md`

---

### Phase 2: LoRA Management (2 weeks)
**Goal:** Connect FLENwheel outputs to unified platform

**Deliverables:**
- ✅ LoRA library management
- ✅ Import FLENwheel exports
- ✅ Persona ↔ LoRA associations
- ✅ Auto-inject LoRAs into ComfyUI workflows

**Success Criteria:**
- Import LoRA file works
- Pipeline uses correct LoRA
- Generation works with persona-specific LoRAs
- Version management functional

---

### Phase 3: Polish & Documentation (1 week)
**Goal:** Production-ready unified platform

**Deliverables:**
- ✅ Comprehensive documentation
- ✅ FLENwheel integration guide
- ✅ Deployment guide
- ✅ Video walkthrough
- ✅ OpenSpec updates

**Success Criteria:**
- New user can onboard in <1 hour
- FLENwheel → Platform workflow documented
- All features documented
- Production deployment successful

---

## VIII. Recommended Next Steps

### Immediate (This Week)

1. **Accept merge-fluffy-train change proposal**
   ```bash
   cd /home/tim/source/activity/turbo-carnival
   # Review openspec/changes/merge-fluffy-train/
   # Create git branch: feature/merge-fluffy-train
   ```

2. **Start Week 1 migrations**
   - Copy Personas pack
   - Copy Content Pillars pack
   - Create basic UI

3. **Set up development environment**
   - Both apps running locally
   - Test fluffy-train features before migration
   - Document current state

### Short-term (Weeks 2-5)

4. **Complete Phase 1 migration**
   - Follow weekly plan in proposal.md
   - Test after each pack
   - Commit cleanly with spec references

5. **Deploy to staging**
   - Test integrated workflow
   - Fix any issues
   - Performance testing

### Medium-term (Weeks 6-8)

6. **Phase 2: LoRA integration**
   - Build LoRA management pack
   - Test FLENwheel export → import
   - Verify ComfyUI integration

7. **Production deployment**
   - Deploy unified platform
   - Migrate users from fluffy-train
   - Archive fluffy-train repo

8. **Documentation**
   - Update all READMEs
   - Create integration guide
   - Video tutorials

---

## IX. Alternative Approaches Considered

### ❌ Alternative 1: Merge All Three into One
**Why Not:**
- FLENwheel is Python, others are Ruby
- Different purposes (training vs production)
- Different users (ML engineer vs content creator)
- Tight coupling would be fragile
- GPU infrastructure mismatch with web server

### ❌ Alternative 2: Keep All Three Separate
**Why Not:**
- Manual data transfer between apps
- Context switching overhead
- No unified persona view
- Duplicate deployment effort
- Hard to maintain three codebases

### ❌ Alternative 3: Build Everything Fresh
**Why Not:**
- Massive time investment
- Throw away working code
- Re-introduce bugs
- No advantage over migration

### ✅ **Chosen: Two Products, Loose Integration**
**Why:**
- Respects different concerns (training vs production)
- Simple file-based integration
- Both products remain focused
- Clean separation of concerns
- Easy to maintain

---

## X. Success Metrics

### Technical Metrics
- [ ] All fluffy-train tests passing in unified platform
- [ ] All turbo-carnival tests passing
- [ ] Zero packwerk violations
- [ ] Page load times <500ms
- [ ] Pipeline execution times unchanged
- [ ] Instagram posting success rate >99%

### User Experience Metrics
- [ ] Workflow time reduced by 50%+ (measured: gap → post)
- [ ] Zero manual export/import steps
- [ ] Single login session
- [ ] All features accessible via web UI
- [ ] Mobile-responsive interface

### Business Metrics
- [ ] 1 codebase instead of 2 (3 → 2)
- [ ] 1 deployment instead of 2 (3 → 2)
- [ ] Maintenance burden reduced 50%
- [ ] Feature development velocity increased
- [ ] User onboarding time <1 hour

---

## XI. Honest Assessment

### What Will Work Well ✅

1. **turbo-carnival + fluffy-train merge is HIGHLY FEASIBLE**
   - Both are Rails 8 apps
   - Both use Packwerk
   - No schema conflicts
   - Complementary features
   - Existing detailed spec available

2. **LoRA integration is STRAIGHTFORWARD**
   - File-based export/import
   - Metadata JSON for automation
   - Clean separation of concerns
   - No tight coupling required

3. **Unified workflow is COMPELLING**
   - Gap analysis → Generate → Vote → Schedule
   - All in one UI
   - Significant time savings
   - Better user experience

### What Will Be Challenging ⚠️

1. **UI Development**
   - fluffy-train is TUI-only
   - Need to build web interfaces for all features
   - Requires thoughtful UX design
   - Estimated 2 weeks of UI work

2. **Polymorphic Image Handling**
   - Clusters need to support Photo AND ImageCandidate
   - Content Strategy selector needs adaptation
   - Testing edge cases thoroughly
   - Estimated 3 days of careful coding

3. **Instagram API Credentials**
   - Complex setup process
   - Long-lived tokens expire
   - Need good documentation
   - Support burden for new users

### What Won't Work ❌

1. **Merging FLENwheel into Rails app**
   - Different languages
   - Different infrastructure needs
   - Different user personas
   - Would create technical debt

2. **Real-time FLENwheel integration**
   - No need for tight coupling
   - Training is offline/batch process
   - File-based integration is sufficient

3. **Single application for everything**
   - Violates separation of concerns
   - Training and production are different
   - GPU needs vs web server needs
   - Creates operational complexity

---

## XII. Final Recommendation

### **Proceed with Two-Phase Plan**

**Phase 1: Merge turbo-carnival + fluffy-train (5 weeks)**
- High confidence in success
- Clear roadmap available
- Significant user value
- Low technical risk
- Well-documented spec

**Phase 2: LoRA Integration Bridge (2 weeks)**
- Connects FLENwheel to unified platform
- Maintains proper separation
- Clean file-based integration
- Low coupling, high cohesion

**Total Effort:** 7 weeks (35 working days)

**Total Risk:** Low-Medium

**Total Value:** High - unified platform with end-to-end workflow

---

## XIII. Questions for You

1. **Existing Data Migration:** Do you have production data in fluffy-train that needs to be migrated, or can we start fresh?

2. **TUI Preference:** Do you want to keep the fluffy-train TUI as an alternative interface, or is full migration to web UI acceptable?

3. **FLENwheel Usage:** How frequently do you retrain LoRAs? Is the file-based export approach acceptable?

4. **Deployment:** Are you planning to self-host or use a platform like Heroku/Fly.io?

5. **Timeline:** Is 7 weeks acceptable, or do you need faster integration?

6. **Priority:** Which features are most critical for your workflow?

---

## XIV. Appendix: Repository Details

### turbo-carnival
- **Purpose:** AI image generation pipeline with voting
- **Tech:** Rails 8.0, PostgreSQL, Packwerk, ViewComponents, Tailwind CSS v4
- **Packs:** pipeline, job_orchestration, comfyui
- **Key Features:** Pipeline execution, voting/ELO, approval gates, tree structure
- **Database:** 8 tables (pipelines, pipeline_steps, pipeline_runs, image_candidates, votes, etc.)
- **Status:** Production-ready, 226+ passing tests
- **Strengths:** Mature web UI, voting interface, ComfyUI integration

### fluffy-train
- **Purpose:** Persona management and Instagram posting
- **Tech:** Rails 8.0, PostgreSQL, Packwerk, ViewComponents, Tailwind CSS v4
- **Packs:** personas, content_pillars, clustering, caption_generations, hashtag_generations, content_strategy, scheduling
- **Key Features:** Gap analysis, AI content planning, Instagram API, content strategy
- **Database:** 14 tables (personas, content_pillars, clusters, photos, scheduling_posts, etc.)
- **Status:** Production-ready TUI, no web interface
- **Strengths:** Strategy-first content model, AI integration, Instagram posting

### FLENwheel
- **Purpose:** Character LoRA training system
- **Tech:** Python, PyTorch, Diffusers, PEFT, Qwen-Image-Edit, FLUX
- **Architecture:** Dual flywheel (character LoRA + editor LoRA)
- **Key Features:** Dataset enrichment, LoRA training, synthetic generation, HITL review
- **Storage:** Filesystem-based (no database)
- **Status:** Planning/early development
- **Strengths:** Specialized ML training, human-in-the-loop, dual flywheel approach

---

**End of Report**

This report provides an honest, complete, actionable assessment of how to integrate the three repositories. The recommended two-phase approach respects the different concerns of each system while creating a powerful unified workflow for persona-based content creation.
