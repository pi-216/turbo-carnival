# TurboCarnival Left-Hand Navigation

> **Status:** UNREVIEWED — predates the 2026-10 rebuild

## Persona Selection
- Select Persona
  - [List of Personas] (personas#index)
  - [Create New Persona] (personas#new)

---

*Once a Persona is chosen, reveal Persona-specific navigation:*

## Persona Home
- Dashboard (personas/:id or personas#show)
  - Overview (scheduled posts, content gaps, recent activity)

---

## Content Pillars
- Pillars List (personas/:persona_id/pillars)
  - [Create Pillar] (new_persona_pillar)
  - For each Pillar:
    - Pillar Overview (persona_pillar)
    - Edit Pillar (edit_persona_pillar)
    - Suggest Content (suggest_persona_pillar)

---

## Posts & Scheduling
- Scheduled Posts List (persona_scheduling_posts)
  - [Browse Photos] (browse_photos_persona_scheduling_posts)
  - [Create Scheduled Post] (new_persona_scheduling_post)
- Suggest Next Post (suggest_next_persona_scheduling_posts)
- For each Post:
  - Post Details (persona_scheduling_post)
  - Suggest Caption (suggest_caption_persona_scheduling_post)
  - Delete Post (persona_scheduling_post - DELETE)

---

## Content Creation Workflow
- Content Suggestions List (persona_content_suggestions)
  - For each Suggestion:
    - Edit/Update Suggestion (edit_content_suggestion, content_suggestion#update)
    - Use Suggestion (use_content_suggestion)
    - Reject Suggestion (reject_content_suggestion)
    - Generate Image (generate_image_content_suggestion)
- Gap Analyses (persona_gap_analyses)
- Campaigns (persona_campaigns)
  - [Create/View Campaign] (persona_campaign, persona_campaigns)

---

## AI Workflow & Human Review
- Runs List (runs#index - optionally scoped to persona via campaign/run association)
  - Start New Run (new_run)
  - For each Run:
    - Run Overview (run#show)
    - Complete Run (complete_run)
    - Card View (card_run)
    - Vote on Images (run_vote)
    - Gallery (run_gallery)
      - Reject (run_gallery_reject)
      - Approve Steps (run_approve_step)
    - Select Winner (select_winner_image_candidate)
    - Unselect Winner (unselect_winner_image_candidate)

---

## Photos
- Gallery (gallery#index)
- Winners (winners#index)
- Candidate Images (candidate_image)

---

## Analysis & Strategy
- Gap Analyses (persona_gap_analyses)
- Content Suggestions (persona_content_suggestions)

---

## Persona Settings
- Edit Persona (edit_persona)
- Delete Persona (persona#destroy)
