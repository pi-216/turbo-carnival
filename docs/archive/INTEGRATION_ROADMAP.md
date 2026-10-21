# Integration Roadmap - Visual Timeline

This document provides a visual, week-by-week roadmap for integrating the three repositories into a unified persona management platform.

---

## Overview: Two Products, One Ecosystem

```
┌─────────────────────────────────────────────────────────────────────┐
│                     UNIFIED ECOSYSTEM                                │
└─────────────────────────────────────────────────────────────────────┘

Product 1: FLENwheel (Standalone)          Product 2: Content Platform (Unified)
Python-based LoRA Training                 Rails-based Content Creation
┌──────────────────────────┐              ┌──────────────────────────────┐
│                          │   exports    │                              │
│  • Qwen-Image-Edit      │──────────────>│  • Persona Management        │
│  • FLUX LoRA Training   │   .safetensors│  • Content Pillars & Gaps    │
│  • Dual Flywheel        │   metadata.json│  • AI Content Generation     │
│  • Human Review         │              │  • ComfyUI Pipeline Execution│
│  • Character Consistency│              │  • Voting & ELO Ranking      │
│                          │              │  • Content Library (Clusters)│
│  Filesystem-based        │              │  • Instagram Scheduling      │
│  No database             │              │                              │
│                          │              │  PostgreSQL database         │
│  Used: Rarely            │              │  Used: Daily                 │
│  (persona creation)      │              │  (content production)        │
└──────────────────────────┘              └──────────────────────────────┘
```

---

## Phase 1: Merge turbo-carnival + fluffy-train

**Duration:** 5 weeks (25 days)  
**Effort:** 13 active development days  
**Risk:** Low

### Week 1: Foundation

```
┌─────────────────────────────────────────────────────────────┐
│ WEEK 1: Personas & Content Pillars                          │
├─────────────────────────────────────────────────────────────┤
│ Day 1-2: Personas Pack                                      │
│   ✓ Copy packs/personas/ from fluffy-train                 │
│   ✓ Migrate personas table schema                          │
│   ✓ Create PersonasController (index, show, new, edit)     │
│   ✓ Build personas views with Tailwind CSS                 │
│   ✓ Test CRUD operations                                   │
│                                                              │
│ Day 3-4: Content Pillars Pack                               │
│   ✓ Copy packs/content_pillars/ from fluffy-train          │
│   ✓ Migrate content_pillars & pillar_cluster_assignments   │
│   ✓ Add pillars section to persona show page               │
│   ✓ Implement gap analysis service                         │
│   ✓ Display gap indicators in UI                           │
│                                                              │
│ Day 5: Testing & Validation                                 │
│   ✓ Run pack tests                                          │
│   ✓ Console validation: create persona, add pillars        │
│   ✓ UI validation: browse personas, view gaps              │
│   ✓ Git commit with spec reference                         │
│                                                              │
│ Deliverable: /personas route with gap analysis              │
└─────────────────────────────────────────────────────────────┘
```

### Week 2: Content Management

```
┌─────────────────────────────────────────────────────────────┐
│ WEEK 2: Clustering & Pipeline Linking                       │
├─────────────────────────────────────────────────────────────┤
│ Day 1-3: Clustering Pack (Adapted)                          │
│   ✓ Copy packs/clustering/ from fluffy-train               │
│   ✓ Create cluster_candidates join table                   │
│   ✓ Adapt Cluster to support Photo AND ImageCandidate      │
│   ✓ Implement polymorphic cluster.images method            │
│   ✓ Build cluster management UI                            │
│   ✓ Test with both Photo and ImageCandidate                │
│                                                              │
│ Day 4: Pipeline → Cluster Linking                           │
│   ✓ Add persona_id, cluster_id to pipelines table          │
│   ✓ Implement auto-link callback on PipelineRun            │
│   ✓ Create "Generate Content" workflow                     │
│   ✓ Test: run completes → winner added to cluster          │
│                                                              │
│ Day 5: Testing & Validation                                 │
│   ✓ Run integration tests                                   │
│   ✓ End-to-end test: gap → generate → auto-link            │
│   ✓ Verify polymorphic cluster behavior                    │
│   ✓ Git commit                                              │
│                                                              │
│ Deliverable: Clusters with ImageCandidates, auto-linking    │
└─────────────────────────────────────────────────────────────┘
```

### Week 3: AI Services

```
┌─────────────────────────────────────────────────────────────┐
│ WEEK 3: AI Content Generation                               │
├─────────────────────────────────────────────────────────────┤
│ Day 1: AI Prompt Generation                                 │
│   ✓ Copy lib/ai/ from fluffy-train                         │
│   ✓ Add ruby-openai gem                                    │
│   ✓ Create CreateContentPipeline service                   │
│   ✓ Add "Generate Content" button to pillar cards          │
│   ✓ Test AI prompt generation                              │
│                                                              │
│ Day 2: Caption Generation                                   │
│   ✓ Copy packs/caption_generations/                        │
│   ✓ Migrate caption tables                                 │
│   ✓ Adapt for ImageCandidate images                        │
│   ✓ Test caption generation                                │
│                                                              │
│ Day 3: Hashtag Generation                                   │
│   ✓ Copy packs/hashtag_generations/                        │
│   ✓ Migrate hashtag tables                                 │
│   ✓ Integrate with caption generation                      │
│   ✓ Test hashtag suggestions                               │
│                                                              │
│ Day 4-5: Testing & Validation                               │
│   ✓ Test full AI flow: gap → prompt → caption → hashtags   │
│   ✓ Verify Gemini API integration                          │
│   ✓ Test error handling                                    │
│   ✓ Git commit                                              │
│                                                              │
│ Deliverable: AI-powered content generation pipeline         │
└─────────────────────────────────────────────────────────────┘
```

### Week 4: Strategy & Scheduling

```
┌─────────────────────────────────────────────────────────────┐
│ WEEK 4: Content Strategy & Instagram Posting                │
├─────────────────────────────────────────────────────────────┤
│ Day 1-2: Content Strategy Pack                              │
│   ✓ Copy packs/content_strategy/                           │
│   ✓ Migrate content_strategy_states & histories            │
│   ✓ Adapt selector for ImageCandidate                      │
│   ✓ Create preview UI for next post                        │
│   ✓ Test strategy selection logic                          │
│                                                              │
│ Day 3: Scheduling & Instagram                               │
│   ✓ Copy packs/scheduling/                                 │
│   ✓ Copy lib/instagram/                                    │
│   ✓ Migrate scheduling_posts table                         │
│   ✓ Add Instagram credentials config                       │
│   ✓ Create scheduling UI                                   │
│   ✓ Test Instagram posting                                 │
│                                                              │
│ Day 4-5: Testing & Validation                               │
│   ✓ End-to-end test: select → caption → schedule → post    │
│   ✓ Verify Instagram API integration                       │
│   ✓ Test error recovery                                    │
│   ✓ Git commit                                              │
│                                                              │
│ Deliverable: Full posting workflow from web UI              │
└─────────────────────────────────────────────────────────────┘
```

### Week 5: UI & Polish

```
┌─────────────────────────────────────────────────────────────┐
│ WEEK 5: Unified Dashboard & Production Prep                 │
├─────────────────────────────────────────────────────────────┤
│ Day 1-3: Unified Dashboard                                  │
│   ✓ Build comprehensive persona show page                  │
│   ✓ Section 1: Content Strategy (pillars + gaps)           │
│   ✓ Section 2: Active Pipelines (status + voting)          │
│   ✓ Section 3: Content Library (clusters with previews)    │
│   ✓ Section 4: Upcoming Posts (schedule calendar)          │
│   ✓ Add "Generate Content" workflow UI                     │
│   ✓ Mobile-responsive design                               │
│                                                              │
│ Day 4-5: Polish & Documentation                             │
│   ✓ Navigation improvements                                │
│   ✓ End-to-end testing checklist                           │
│   ✓ Update README                                           │
│   ✓ Copy fluffy-train OpenSpecs to openspec/specs/         │
│   ✓ Create deployment guide                                │
│   ✓ Git commit: "Merge complete"                           │
│                                                              │
│ Deliverable: Production-ready unified application           │
└─────────────────────────────────────────────────────────────┘
```

**End of Phase 1: Single unified Rails application with end-to-end workflow**

---

## Phase 2: LoRA Integration Bridge

**Duration:** 2 weeks (10 days)  
**Effort:** 7 active development days  
**Risk:** Low

### Week 6: LoRA Management

```
┌─────────────────────────────────────────────────────────────┐
│ WEEK 6: LoRA Library & Import                               │
├─────────────────────────────────────────────────────────────┤
│ Day 1-2: LoRA Management Pack                               │
│   ✓ Create packs/lora_management/                          │
│   ✓ Create LoraModel model                                 │
│     - name, version, file_path, metadata                   │
│     - persona_id, model_type                               │
│   ✓ Create PersonaLoraMapping model                        │
│     - persona_id, lora_model_id, weight, primary           │
│   ✓ Migration for lora_models & persona_lora_mappings      │
│                                                              │
│ Day 3-4: LoRA Import UI                                     │
│   ✓ Build LoRA library view                                │
│   ✓ Import form for FLENwheel outputs                      │
│   ✓ Parse metadata.json from FLENwheel                     │
│   ✓ Associate LoRAs with personas                          │
│   ✓ LoRA version management UI                             │
│                                                              │
│ Day 5: Testing & Validation                                 │
│   ✓ Test import workflow                                   │
│   ✓ Verify LoRA associations                               │
│   ✓ Test version management                                │
│   ✓ Git commit                                              │
│                                                              │
│ Deliverable: LoRA library with import capability            │
└─────────────────────────────────────────────────────────────┘
```

### Week 7: ComfyUI Integration

```
┌─────────────────────────────────────────────────────────────┐
│ WEEK 7: LoRA Injection into Pipelines                       │
├─────────────────────────────────────────────────────────────┤
│ Day 1-2: BuildJobPayload Extension                          │
│   ✓ Detect persona_id in PipelineRun                       │
│   ✓ Load associated LoRA files from PersonaLoraMapping     │
│   ✓ Inject LoRA nodes into ComfyUI workflow JSON           │
│   ✓ Support template variables: {{lora_path}}, {{lora_weight}}│
│   ✓ Handle multiple LoRAs per persona                      │
│                                                              │
│ Day 3-4: Pipeline Integration                               │
│   ✓ Add LoRA selection to persona settings                 │
│   ✓ Pipeline creation auto-includes persona LoRAs          │
│   ✓ Test LoRA injection in job payload                     │
│   ✓ Verify ComfyUI accepts LoRA workflows                  │
│   ✓ Test generation with character LoRAs                   │
│                                                              │
│ Day 5: Testing & Validation                                 │
│   ✓ End-to-end test: FLENwheel export → import → generate  │
│   ✓ Verify character consistency                           │
│   ✓ Performance testing                                    │
│   ✓ Git commit                                              │
│                                                              │
│ Deliverable: Pipelines use persona-specific LoRAs           │
└─────────────────────────────────────────────────────────────┘
```

**End of Phase 2: FLENwheel outputs automatically used in content generation**

---

## Phase 3: Production Deployment

**Duration:** 1 week (5 days)  
**Effort:** 3 active development days  
**Risk:** Low

### Week 8: Launch

```
┌─────────────────────────────────────────────────────────────┐
│ WEEK 8: Documentation, Deployment & Handoff                 │
├─────────────────────────────────────────────────────────────┤
│ Day 1-2: Documentation                                      │
│   ✓ Complete README with all features                      │
│   ✓ FLENwheel integration guide                            │
│   ✓ Environment setup guide                                │
│   ✓ API credentials documentation                          │
│   ✓ Troubleshooting guide                                  │
│   ✓ Video walkthrough (optional)                           │
│                                                              │
│ Day 3-4: Deployment                                         │
│   ✓ Deploy to staging environment                          │
│   ✓ Test full workflow in staging                          │
│   ✓ Performance profiling                                  │
│   ✓ Deploy to production                                   │
│   ✓ Migrate users from old fluffy-train                    │
│                                                              │
│ Day 5: Cleanup                                              │
│   ✓ Archive fluffy-train repository                        │
│   ✓ Update GitHub READMEs with migration notice            │
│   ✓ Redirect old docs to new unified app                   │
│   ✓ Final testing                                           │
│                                                              │
│ Deliverable: Production-ready unified platform              │
└─────────────────────────────────────────────────────────────┘
```

---

## Workflow Comparison: Before vs After

### Before Integration (Current State)

```
┌──────────────────────────────────────────────────────────────────┐
│ USER WORKFLOW: Create & Post Content (9 STEPS)                   │
└──────────────────────────────────────────────────────────────────┘

1. Open fluffy-train TUI
   └─ Run gap analysis
   └─ See "Thanksgiving" pillar is low

2. Generate AI prompt
   └─ TUI command: generate_prompt --pillar thanksgiving
   └─ Copy prompt to clipboard

3. Switch to ComfyUI
   └─ Paste prompt manually
   └─ Adjust settings
   └─ Queue generation

4. Wait for generation
   └─ Monitor ComfyUI interface

5. Open turbo-carnival
   └─ Create new pipeline manually
   └─ Paste workflow JSON
   └─ Create run

6. Vote on candidates
   └─ turbo-carnival voting interface
   └─ Approve gates

7. Export winner
   └─ Download image from turbo-carnival
   └─ Save to local directory

8. Back to fluffy-train
   └─ Import images to cluster
   └─ TUI command: import_to_cluster

9. Schedule post
   └─ TUI command: schedule_post
   └─ Enter caption manually

TIME: 45-60 minutes
CONTEXT SWITCHES: 3 applications
MANUAL STEPS: 9
ERROR PRONE: High (copy-paste, manual export)
```

### After Integration (Target State)

```
┌──────────────────────────────────────────────────────────────────┐
│ USER WORKFLOW: Create & Post Content (5 STEPS)                   │
└──────────────────────────────────────────────────────────────────┘

1. Open Persona Dashboard
   └─ See gap warning on "Thanksgiving" pillar
   └─ RED indicator: 0 images

2. Click "Generate Content"
   └─ AI creates prompt automatically
   └─ System creates cluster + pipeline + run
   └─ ComfyUI generation starts
   └─ Redirects to voting interface

3. Vote & Approve
   └─ Vote on candidates
   └─ Approve gates
   └─ Mark run complete

4. Winner Auto-Linked
   └─ System automatically adds winner to cluster
   └─ Gap indicator updates to GREEN
   └─ Returns to dashboard

5. Click "Schedule Post"
   └─ AI generates caption
   └─ AI suggests hashtags
   └─ Select time
   └─ Confirm

TIME: 5-10 minutes
CONTEXT SWITCHES: 0 (all in one UI)
MANUAL STEPS: 5 (all clicks)
ERROR PRONE: Low (automated)
```

**Time Savings:** 75% reduction (60min → 10min)  
**User Experience:** Dramatically improved  
**Error Rate:** Significantly reduced

---

## Database Evolution

### Before Integration

```
fluffy-train DB                     turbo-carnival DB
┌──────────────┐                   ┌──────────────────┐
│ personas     │                   │ pipelines        │
│ content_pillars│                 │ pipeline_steps   │
│ clusters     │                   │ pipeline_runs    │
│ photos       │                   │ image_candidates │
│ scheduling_posts│                │ votes            │
└──────────────┘                   └──────────────────┘
  No overlap                         Different domains
```

### After Integration

```
Unified Database
┌─────────────────────────────────────────────────────────────┐
│ Core Persona Layer                                          │
│   • personas (single source of truth)                       │
│   • content_pillars (strategy)                              │
│                                                              │
│ Content Library Layer                                       │
│   • clusters (themes)                                       │
│   • cluster_candidates (join: clusters ↔ image_candidates) │
│   • photos (legacy, optional)                               │
│   • pillar_cluster_assignments                              │
│                                                              │
│ Generation Layer                                            │
│   • pipelines (templates)                                   │
│   • pipeline_steps (workflow stages)                        │
│   • pipeline_runs (executions)                              │
│   • pipeline_run_steps (approval gates)                     │
│   • image_candidates (generated images)                     │
│   • votes (ELO ranking)                                     │
│   • comfyui_jobs (generation jobs)                          │
│                                                              │
│ Publishing Layer                                            │
│   • scheduling_posts (Instagram queue)                      │
│   • content_strategy_states (strategy tracking)             │
│   • content_strategy_histories (post history)               │
│                                                              │
│ LoRA Management Layer (Phase 2)                             │
│   • lora_models (trained LoRAs from FLENwheel)              │
│   • persona_lora_mappings (persona ↔ LoRA associations)     │
└─────────────────────────────────────────────────────────────┘
```

---

## Feature Matrix by Week

| Feature | Week 1 | Week 2 | Week 3 | Week 4 | Week 5 | Week 6 | Week 7 | Week 8 |
|---------|--------|--------|--------|--------|--------|--------|--------|--------|
| Persona CRUD | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Content Pillars | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Gap Analysis | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Clustering | | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Auto-Linking | | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| AI Prompts | | | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| AI Captions | | | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| AI Hashtags | | | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Content Strategy | | | | ✅ | ✅ | ✅ | ✅ | ✅ |
| Instagram Posting | | | | ✅ | ✅ | ✅ | ✅ | ✅ |
| Unified Dashboard | | | | | ✅ | ✅ | ✅ | ✅ |
| LoRA Library | | | | | | ✅ | ✅ | ✅ |
| LoRA Auto-Inject | | | | | | | ✅ | ✅ |
| Production Deploy | | | | | | | | ✅ |

---

## Risk Mitigation Timeline

```
Week 1-2: Foundation (LOW RISK)
├─ Risk: Schema conflicts
├─ Mitigation: Both apps analyzed, no conflicts found
└─ Mitigation: Test after each pack migration

Week 3-4: Integration (MEDIUM RISK)
├─ Risk: Polymorphic image handling bugs
├─ Mitigation: Comprehensive unit tests
├─ Mitigation: Integration tests for cluster.images
└─ Mitigation: Manual validation with sample data

Week 5: UI (LOW RISK)
├─ Risk: Poor user experience
├─ Mitigation: Both apps use same design system
├─ Mitigation: Wireframe before implementation
└─ Mitigation: User testing before finalization

Week 6-7: LoRA Integration (LOW RISK)
├─ Risk: ComfyUI workflow injection failures
├─ Mitigation: Test with sample LoRA files
├─ Mitigation: Validate JSON before submission
└─ Mitigation: Error handling and logging

Week 8: Deployment (LOW RISK)
├─ Risk: Production issues
├─ Mitigation: Staging environment testing
├─ Mitigation: Gradual rollout
└─ Mitigation: Keep old apps running during transition
```

---

## Success Checklist

### End of Phase 1 (Week 5)
- [ ] All fluffy-train packs migrated
- [ ] All tests passing (226+ from turbo-carnival, 100+ from fluffy-train)
- [ ] Zero packwerk violations
- [ ] Personas dashboard shows: pillars, gaps, pipelines, clusters, posts
- [ ] Gap analysis → Generate → Vote → Auto-link workflow works
- [ ] AI content generation functional
- [ ] Instagram posting works (test post successful)
- [ ] Performance: page loads <500ms
- [ ] Documentation: README updated

### End of Phase 2 (Week 7)
- [ ] LoRA library functional
- [ ] Import FLENwheel outputs works
- [ ] Persona ↔ LoRA associations work
- [ ] Pipelines auto-inject persona LoRAs
- [ ] Generation with character LoRAs works
- [ ] Character consistency verified
- [ ] Version management functional
- [ ] Documentation: FLENwheel integration guide

### End of Phase 3 (Week 8)
- [ ] Staging deployment successful
- [ ] Production deployment successful
- [ ] All features work in production
- [ ] Performance acceptable under load
- [ ] User onboarding guide complete
- [ ] Video walkthrough created
- [ ] Old repositories archived
- [ ] Redirects and notices in place

---

## Repository Status Evolution

### Week 0 (Current State)
```
FLENwheel          ✅ Active (planning phase)
turbo-carnival     ✅ Active (production)
fluffy-train       ✅ Active (production)
```

### Week 5 (Phase 1 Complete)
```
FLENwheel          ✅ Active (standalone, no changes)
turbo-carnival     ✅ Active (unified platform)
fluffy-train       ⚠️  Deprecated (merged into turbo-carnival)
```

### Week 8 (All Phases Complete)
```
FLENwheel          ✅ Active (standalone LoRA training)
turbo-carnival     ✅ Active (renamed: "Persona Platform")
fluffy-train       📦 Archived (migration complete notice)
```

---

## Next Actions

1. **This Week:** Review this roadmap and INTEGRATION_REPORT.md
2. **Next Week:** Start Week 1 migrations (Personas + Pillars)
3. **Ongoing:** Weekly check-ins, adjust timeline as needed
4. **End of Week 5:** Demo unified platform
5. **End of Week 7:** Production deployment

**Questions? Feedback? Adjustments needed?**

Contact: See repository issues or discussions
