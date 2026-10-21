# Turbo Carnival

> **Status:** UNREVIEWED — app overview, 983 lines — large enough to be its own truth source

Unified Persona-Based Content Creation and Instagram Scheduling Platform

## Overview

This application is a **unified content creation and social media management platform** that combines AI image generation, content strategy, and Instagram scheduling into a single workflow. It manages the entire content lifecycle from persona creation to automated posting:

### Core Capabilities

**🎭 Persona Management**
- Create and manage multiple social media personas
- Each persona has distinct content pillars (themes), caption configs, and hashtag strategies
- Visual dashboard showing content gaps and opportunities per persona

**📊 Content Strategy & Gap Analysis**
- Define content pillars (e.g., "Thanksgiving", "Fitness", "Travel") with weights and priorities
- Automated gap analysis identifies under-represented content areas
- Visual indicators show which pillars need more content (red = urgent, green = satisfied)
- Time-based pillar scheduling (start/end dates for seasonal content)

**🎨 AI Image Generation Pipeline**
- Multi-stage ComfyUI workflow execution (Base → Face Fix → Hand Fix → Upscale)
- Intelligent job selection using ELO-weighted prioritization
- Tree structure manages thousands of image candidates per run
- A/B voting interface for human curation and quality control
- Autonomous workers continuously generate and process images
- Per-run isolation: multiple pipelines can run simultaneously

**📸 Content Library**
- Organized photo library per persona
- Photos linked to content pillars for strategic organization
- Support for both uploaded photos and AI-generated images
- Gallery views with per-step filtering and approval gates

**📝 AI Caption & Hashtag Generation**
- Automated caption generation using Google Gemini API
- Context-aware captions based on persona voice and content pillar
- Smart hashtag suggestions with configurable strategies
- Manual editing and approval workflow

**📅 Instagram Scheduling & Posting**
- Schedule posts with automatic publishing via Instagram Graph API
- Visual calendar interface showing upcoming posts
- Draft management with caption and image preview
- Automated hourly posting via cron jobs
- Status tracking: draft → scheduled → posted/failed

**⚙️ Workflow Automation**
- Background workers (Sidekiq) for autonomous image generation
- Automated content suggestion based on gap analysis
- One-click content creation: gap → AI prompt → generation → voting → approval → scheduling
- Integration with ComfyUI for GPU-accelerated image generation


## What Can This Application Do?

This platform enables end-to-end content creation and social media management:

### Complete Workflow Example

1. **Create a Persona** → Define "Sarah - Fitness Influencer"
2. **Set Content Strategy** → Add pillars: "Gym Workouts" (30%), "Meal Prep" (25%), "Motivation" (25%), "Lifestyle" (20%)
3. **Run Gap Analysis** → System identifies "Gym Workouts" needs 5 more photos
4. **Generate AI Content** → Click "Generate Content" → AI creates prompt → ComfyUI generates images
5. **Vote & Curate** → A/B voting selects best images → Approve final candidates
6. **Create Post** → Select image → AI generates caption → Add hashtags → Schedule for 7 PM
7. **Automated Posting** → Cron job publishes to Instagram at scheduled time

### Key Capabilities

✅ **Manage multiple personas** with distinct content strategies  
✅ **AI-powered image generation** through ComfyUI integration  
✅ **Intelligent gap analysis** identifies content needs automatically  
✅ **ELO-based voting** ensures only best content makes it to Instagram  
✅ **AI caption generation** with persona-specific voice and style  
✅ **Automated Instagram posting** on schedule via Graph API  
✅ **Content library** organized by pillars and personas  
✅ **Real-time monitoring** of generation pipelines and post status

## Getting Started

### Prerequisites

- **Ruby 3.4.5** (via rbenv or RVM)
- **PostgreSQL 14+** (for JSONB support)
- **Bundler** (gem dependency management)
- **Node.js 18+** (for asset compilation)
- **ComfyUI instance** running (optional, for AI image generation)
- **Instagram Business Account** (optional, for posting features)
- **Google Gemini API key** (optional, for AI caption generation)

### Setup

```bash
# Install dependencies
bundle install

# Setup database
bin/rails db:create db:migrate

# Create example pipeline
bin/rails pipeline:setup_example

# Run tests
bin/rspec

# Validate pack boundaries
bin/packwerk check
bin/packwerk validate

# Code style check
bundle exec rubocop
```

### Quick Start: Web Interface

The web interface provides persona management, content strategy, and Instagram scheduling:

```bash
# Start the Rails server
bin/rails server

# Visit the dashboard
open http://localhost:3000

# Main Features:
# - Dashboard: Overview of all personas, pillars, and recent runs
# - Personas (/personas): Manage personas and content pillars
# - Runs (/runs): Monitor AI generation pipelines
# - Scheduling (/personas/:id/scheduling/posts): Create and schedule Instagram posts
# - Gap Analysis: View content gaps and generate suggestions
```

**Key Web Features**:
- **Dashboard**: Bird's-eye view of all personas, content pillars, photos, and active runs
- **Persona Show Page**: Complete persona overview with pillars, gap analysis, and content suggestions
- **Content Pillar Management**: Create/edit pillars with weights, priorities, and date ranges
- **Run Monitoring**: Live updates via Turbo Streams when new candidates are generated
- **Voting Interface**: A/B comparison with ELO ranking per run
- **Gallery Views**: Browse images by pipeline step with approval gates
- **Post Scheduling**: Visual interface for creating and scheduling Instagram posts
- **Caption Generation**: AI-powered caption suggestions with manual editing

### Quick Start: Content Creation Workflow

Complete workflow from gap analysis to Instagram posting:

```bash
# 1. Create a persona
open http://localhost:3000/personas/new

# 2. Add content pillars (e.g., "Fitness", "Travel", "Food")
# Visit persona page and click "New Pillar"

# 3. Run gap analysis to identify content needs
# Gaps automatically displayed on persona dashboard

# 4. Generate content for a gap
# Click "Generate Content" on a pillar with low content

# 5. Vote on generated images
open http://localhost:3000/runs/:id/vote

# 6. Approve final images
open http://localhost:3000/runs/:id/gallery

# 7. Schedule Instagram post
open http://localhost:3000/personas/:id/scheduling/posts/new

# 8. AI generates caption automatically
# Edit caption and schedule for posting
```

### Quick Start: Running Pipelines

```bash
# 1. Create an example pipeline with 4 steps
bin/rails pipeline:setup_example

# 2. Update ComfyUI workflow JSON for your actual workflows
#    (Edit in Rails console or database)

# 3. Start autonomous workers
bundle exec sidekiq

# 4. Create more runs as needed
bin/rails pipeline:create_run[3,"Beach Shoot","person on the beach, sunset"]
```

See `OPS.md` for the render-pipeline mechanics (the validated configuration lives in `docs/baseline-config.md`).

### Running Autonomous Workers

To run the system autonomously:

```bash
# Start the Sidekiq workers
bundle exec sidekiq

# This starts both workers:
# - JobSubmitterWorker: Selects and submits jobs every 10s
# - JobPollerWorker: Polls and processes jobs every 5s
```

Configure via environment variables:

```bash
# ComfyUI connection
COMFYUI_BASE_URL=http://localhost:8188  # API endpoint
COMFYUI_TIMEOUT=300                      # Request timeout (seconds)
COMFYUI_MAX_RETRIES=3                    # Retry attempts

# Worker intervals
COMFYUI_SUBMIT_INTERVAL=10  # Seconds between job submissions
COMFYUI_POLL_INTERVAL=5     # Seconds between status polls

# Job selection algorithm
MAX_CHILDREN_PER_NODE=2  # Max children per candidate (breadth-first: 2-3 recommended)
TARGET_LEAF_NODES=10     # Target final candidates

bundle exec sidekiq
```

### Instagram Scheduling Setup

To enable automated Instagram posting:

1. **Configure Instagram Credentials**

Add your Instagram Business Account credentials to Rails encrypted credentials:

```bash
bin/rails credentials:edit
```

```yaml
instagram:
  app_id: "your_facebook_app_id"
  app_secret: "your_facebook_app_secret"
  access_token: "your_long_lived_user_access_token"
  account_id: "your_instagram_business_account_id"

gemini:
  api_key: "your_gemini_api_key"  # For AI caption generation
```

2. **Set Up Cron Job for Automated Posting**

Add to your crontab (runs every hour):

```bash
crontab -e
```

```
0 * * * * cd /path/to/turbo-carnival && bin/scheduled_posting.sh
```

3. **Test Manual Posting**

```bash
# Schedule a post immediately
bin/rails scheduling:post_scheduled

# Or via web interface
open http://localhost:3000/personas/:id/scheduling/posts/new
```

See `OPS.md` for the posting rail (the hourly `bin/scheduled_posting.sh`).

**Job Selection Strategy**:
The system uses a **per-parent breadth-first** approach with **round-robin run selection**:

**Per-Run Round-Robin**:
- Multiple PipelineRuns can be active simultaneously
- System cycles through runs fairly: Run A → Run B → Run C → Run A...
- Each run progresses independently
- Completed runs are excluded from job selection

**Per-Parent Breadth-First**:
- Each parent candidate gets N children (default: 2) before moving to next step
- Ensures full tree exploration - no "bottom-right" branch starvation
- Tree grows geometrically: 2 → 4 → 8 → 16 → 32 candidates per step
- Control growth by rejecting low-ELO candidates early

**Example Tree Growth (N=2)**:
```
Step 1: [Parent A, Parent B]           = 2 total
Step 2: [2 from A, 2 from B]           = 4 total  
Step 3: [2 from each of 4 parents]     = 8 total
Step 4: [2 from each of 8 parents]     = 16 total
```

**Configuration**:
- `MAX_CHILDREN_PER_NODE=2` - Children per parent (keep at 2-3 for manageable growth)
- `TARGET_LEAF_NODES=10` - Maintain this many candidates in final step (deprecated in favor of per-parent strategy)


## How It Works

### Core Data Models

**Persona** - Social media identity/character
- Has many content pillars (content themes)
- Has many photos (content library)
- Stores caption_config (JSONB) for AI caption generation settings
- Stores hashtag_strategy (JSONB) for hashtag selection preferences

**ContentPillar** - Content theme/category (e.g., "Fitness", "Travel")
- Belongs to a persona
- Has weight (0-100) for content distribution targets
- Has priority (1-5) for scheduling preference
- Optional date range for seasonal content
- Has many photos

**ContentPillars::Photo** - Individual photo in content library
- Belongs to a content pillar
- ActiveStorage attachment for image file
- Can be uploaded or AI-generated

**Scheduling::Post** - Instagram post
- Belongs to persona
- References a photo
- Stores caption, hashtags, scheduled_at timestamp
- State machine: draft → scheduled → posted/failed
- Tracks provider_post_id from Instagram API

**Pipeline** - Reusable AI generation pipeline template
- Has many ordered pipeline steps
- Has many pipeline runs
- Can be linked to persona

**PipelineStep** - Stage in generation pipeline
- Stores ComfyUI workflow JSON with `{{template_variables}}`
- Boolean flags for variable requirements
- Per-step N value for generation control

**PipelineRun** - Single execution of a pipeline
- Stores run-specific variables in JSONB
- Has target_folder for organizing output images
- Status tracking: pending → running → completed/failed
- Creates many ImageCandidates

**ImageCandidate** - Single AI-generated image
- Belongs to pipeline step and pipeline run
- Self-referential tree structure (parent/children)
- ELO score (default 1000) updated via A/B voting
- State machine: active → rejected, with winner flag
- Image path stored for use by subsequent steps


### Variable System & Template Substitution

The variable system allows you to parameterize ComfyUI workflows and reuse pipeline definitions with different inputs.

#### How It Works

1. **Define template variables** in your ComfyUI workflow JSON using `{{variable_name}}` syntax
2. **Declare requirements** on each PipelineStep using boolean flags
3. **Provide values** when creating a PipelineRun via the `variables` JSONB field
4. **Template substitution** happens automatically when building job payloads

#### Template Variable Syntax

In your ComfyUI workflow JSON, use double curly braces for variables:

```json
{
  "107": {
    "inputs": {
      "seed": {{seed}}
    },
    "class_type": "Seed"
  },
  "121": {
    "inputs": {
      "text": "{{prompt}}"
    },
    "class_type": "Text Multiline"
  },
  "122": {
    "inputs": {
      "filename_prefix": "sarah1a3/{{run_name}}_base_image_",
      "images": ["77", 0]
    },
    "class_type": "SaveImage"
  }
}
```

**Important**: 
- Numeric values: `"seed": {{seed}}` (no quotes around template)
- String values: `"text": "{{prompt}}"` (quotes around entire string)
- The system does simple string replacement, so format accordingly

#### PipelineStep Variable Requirement Flags

Each PipelineStep declares what data it needs using boolean flags:

**`needs_run_prompt`** (deprecated - use `needs_run_variables` instead)
- Legacy flag: Makes `prompt` from PipelineRun variables available
- Use `needs_run_variables` for new implementations

**`needs_parent_image_path`**
- Automatically provides `{{parent_image_path}}` template variable
- Value comes from the parent ImageCandidate's `image_path` field
- Used for steps that process existing images (face fix, upscale, etc.)
- Example: `"image": "{{parent_image_path}}"`

**`needs_run_variables`**
- Provides ALL variables from the PipelineRun's `variables` JSONB field
- Most flexible option - use for any custom variables
- Variables become available as template substitutions
- Example variables: `prompt`, `seed`, `run_name`, `persona_id`, `style`, etc.

#### Variable Substitution Process

When `BuildJobPayload` constructs a job for ComfyUI:

```ruby
# 1. Load workflow JSON template from PipelineStep
workflow_json = pipeline_step.comfy_workflow_json

# 2. Replace all {{variable}} placeholders with actual values
pipeline_run.variables.each do |key, value|
  workflow_json.gsub!("{{#{key}}}", value.to_s)
end

# 3. If needs_parent_image_path, add parent's path
if pipeline_step.needs_parent_image_path
  workflow_json.gsub!("{{parent_image_path}}", parent_candidate.image_path)
end

# 4. Parse as JSON and submit to ComfyUI
workflow = JSON.parse(workflow_json)
```

#### Example: Complete Pipeline Setup

```ruby
# Create pipeline template (define once)
pipeline = Pipeline.create!(name: "Portrait Generation")

# Step 1: Base image generation
step1 = pipeline.pipeline_steps.create!(
  name: "Base Image",
  order: 1,
  comfy_workflow_json: File.read("workflows/base_image.json"),
  needs_run_variables: true  # Needs: seed, prompt, run_name
)

# Step 2: Face refinement
step2 = pipeline.pipeline_steps.create!(
  name: "Face Fix",
  order: 2,
  comfy_workflow_json: File.read("workflows/face_fix.json"),
  needs_run_variables: true,      # Needs: seed, run_name
  needs_parent_image_path: true   # Needs: parent image
)

# Step 3: Final upscale
step3 = pipeline.pipeline_steps.create!(
  name: "Upscale",
  order: 3,
  comfy_workflow_json: File.read("workflows/upscale.json"),
  needs_run_variables: true,      # Needs: seed, prompt, run_name
  needs_parent_image_path: true   # Needs: parent image
)

# Execute multiple times per day with different variables
run1 = pipeline.pipeline_runs.create!(
  name: "Morning Gym Session",
  target_folder: "runs/2025-11-10/gym",
  variables: {
    seed: 1000001,
    prompt: "person at the gym, athletic wear, exercising",
    run_name: "gym_session",
    persona_id: 123,
    style: "photorealistic"
  }
)

run2 = pipeline.pipeline_runs.create!(
  name: "Afternoon Coffee Shop",
  target_folder: "runs/2025-11-10/cafe",
  variables: {
    seed: 1000002,
    prompt: "person at coffee shop, casual clothes, reading book",
    run_name: "cafe_session",
    persona_id: 123,
    style: "photorealistic"
  }
)
```

#### ComfyUI Output Requirements

**Critical**: Your workflow MUST include a SaveImage node (or similar output node) or ComfyUI will reject it with "Prompt has no outputs".

```json
{
  "122": {
    "inputs": {
      "filename_prefix": "{{run_name}}_step1_",
      "images": ["77", 0]
    },
    "class_type": "SaveImage"
  }
}
```

**Output file structure**:
- ComfyUI saves to its `output/` directory
- Filename: `{filename_prefix}{number}_.png`
- Example: `gym_session_step1_00001_.png`
- The system retrieves this path via ComfyUI's history API
- Path is stored in ImageCandidate's `image_path` field for use by child steps

#### Common Variable Patterns

**Required for most workflows**:
- `seed` - Random seed for reproducibility (numeric, no quotes in template)
- `prompt` - Text description of desired image
- `run_name` - Identifier for organizing outputs

**Optional but recommended**:
- `persona_id` - Reference to character/subject being generated
- `style` - Art style descriptor ("photorealistic", "anime", etc.)
- `negative_prompt` - Things to avoid in generation
- `cfg_scale` - Classifier-free guidance strength
- `steps` - Number of diffusion steps

**Step-specific**:
- `parent_image_path` - Automatically provided when `needs_parent_image_path: true`
- Any custom parameters your ComfyUI workflow requires


## Examples

### Example Usage

#### Quick Start with Rake Task

```bash
# Create complete 4-step portrait pipeline with sample run
bin/rails pipeline:setup_example

# Create additional runs
bin/rails pipeline:create_run[3,"Cafe Shoot","person at coffee shop, reading"]
bin/rails pipeline:create_run[3,"Park Shoot","person in park, walking dog"]

# Start autonomous workers
bundle exec sidekiq
```

For the command inventory and runbook, see `OPS.md`.

#### Pipeline Setup (Manual)

```ruby
# Define pipeline template once
pipeline = Pipeline.create!(name: "Portrait Generation")

# Step 1: Base image - needs prompt, seed, run_name from variables
step1 = pipeline.pipeline_steps.create!(
  name: "Base Image", 
  order: 1,
  comfy_workflow_json: '{
    "seed_node": {"inputs": {"seed": {{seed}}}},
    "prompt_node": {"inputs": {"text": "{{prompt}}"}},
    "save_node": {"inputs": {"filename_prefix": "{{run_name}}_base_"}}
  }',
  needs_run_variables: true  # Provides: seed, prompt, run_name, and all other variables
)

# Step 2: Face fix - needs parent image and seed/run_name
step2 = pipeline.pipeline_steps.create!(
  name: "Face Fix",
  order: 2,
  comfy_workflow_json: '{
    "load_node": {"inputs": {"image": "{{parent_image_path}}"}},
    "seed_node": {"inputs": {"seed": {{seed}}}},
    "save_node": {"inputs": {"filename_prefix": "{{run_name}}_face_"}}
  }',
  needs_run_variables: true,      # Provides: seed, run_name
  needs_parent_image_path: true   # Provides: parent_image_path
)

# Step 3: Upscale - needs both prompt and parent image
step3 = pipeline.pipeline_steps.create!(
  name: "Upscale",
  order: 3,
  comfy_workflow_json: '{
    "load_node": {"inputs": {"image": "{{parent_image_path}}"}},
    "prompt_node": {"inputs": {"text": "{{prompt}}"}},
    "save_node": {"inputs": {"filename_prefix": "{{run_name}}_upscale_"}}
  }',
  needs_run_variables: true,      # Provides: prompt, seed, run_name
  needs_parent_image_path: true   # Provides: parent_image_path
)
```

#### Execute Pipeline Runs

```ruby
# Run multiple times per day with different variables
gym_run = pipeline.pipeline_runs.create!(
  name: "Gym Shoot",
  target_folder: "/storage/runs/2025-11-09/gym-shoot",
  variables: {
    seed: 1000001,
    prompt: "person at the gym, athletic wear",
    run_name: "gym_shoot",
    persona_id: 123
  }
)

home_run = pipeline.pipeline_runs.create!(
  name: "Home Shoot",
  target_folder: "/storage/runs/2025-11-09/home-shoot",
  variables: {
    seed: 1000002,
    prompt: "person at home, casual clothes",
    run_name: "home_shoot",
    persona_id: 123
  }
)

# Each run's variables are substituted into step workflows
# All generated images organized in the run's target_folder
# gym_shoot_base_00001_.png, gym_shoot_face_00001_.png, etc.
```

#### Select Next Job

```ruby
# The system intelligently decides which job to run next
result = SelectNextJob.call

case result.mode
when :child_generation
  # Generate child from selected parent candidate
  parent = result.parent_candidate
  next_step = result.next_step
  
  # Submit job to ComfyUI (workers do this automatically)
  SubmitJob.call(
    pipeline_step: next_step,
    pipeline_run: parent.pipeline_run,
    parent_candidate: parent
  )

when :base_generation
  # No eligible parents, but need more final candidates
  # Generate new base image
  step = result.next_step  # First step
  
  SubmitJob.call(
    pipeline_step: step,
    pipeline_run: PipelineRun.last  # Or create new run
  )

when :no_work
  # Pipeline is complete or no deficit
  # System is satisfied
end
```


### Monitoring

```ruby
# In Rails console

# Check pipeline status
pipeline = Pipeline.find(1)
pipeline.pipeline_runs.each do |run|
  puts "#{run.name}: #{run.image_candidates.count} images"
end

# View job queue
ComfyuiJob.in_flight.count   # Currently processing
ComfyuiJob.pending.count     # Waiting to submit
ComfyuiJob.completed.count   # Finished

# See what's next
result = SelectNextJob.call
puts "Next: #{result.mode} - #{result.next_step&.name}"
```


### Next Steps

The system is fully functional! Future enhancements:

- 🎨 Web UI for viewing ImageCandidates
- 🗳️ A/B voting interface for ELO score updates
- 📊 Dashboard showing pipeline progress and statistics
- 🔍 Image gallery with filtering and search
- 📈 Analytics on generation efficiency and costs



## Technical Details

## Tech Stack

- **Ruby 3.4.5** / **Rails 8.0.4** - Web framework
- **PostgreSQL** - Database with JSONB for flexible metadata storage
- **Puma** - Web server
- **Sidekiq 7.3.9** - Background job processing
- **Solid Cache/Queue/Cable** - Database-backed Rails infrastructure
- **Packwerk** + **packs-rails** - Modular architecture with enforced boundaries
- **ViewComponent** - Reusable UI components
- **Tailwind CSS v4** - Utility-first styling
- **Turbo Streams** - Real-time UI updates
- **GLCommand** - Business logic command pattern with rollback support
- **State Machines** - Model state management
- **Google Gemini API** - AI caption generation
- **Instagram Graph API** - Automated Instagram posting
- **ComfyUI API** - AI image generation integration
- **RSpec** + **FactoryBot** - Testing


## Architecture

### Packs Structure

The application uses `packs-rails` for modular architecture:

```
packs/
  personas/           # Persona management
    app/
      models/
        persona.rb
      services/
        caption_config.rb
        hashtag_strategy.rb
  
  content_pillars/    # Content strategy and themes
    app/
      models/
        content_pillar.rb
        photo.rb
      commands/
        create_pillar.rb
        
  gap_analysis/       # Content gap identification
    app/
      models/
        gap_analysis.rb
      commands/
        analyze_gaps.rb
        
  content_strategy/   # Post selection strategy
    app/
      models/
        content_strategy_state.rb
      commands/
        select_next_post.rb
  
  scheduling/         # Instagram posting
    app/
      models/
        post.rb
      commands/
        schedule_post.rb
        publish_to_instagram.rb
      workers/
        scheduled_posting_worker.rb
        
  caption_generation/ # AI caption creation
    app/
      commands/
        generate_caption.rb
      services/
        gemini_client.rb
  
  pipeline/           # AI image generation pipelines
    app/
      models/
        pipeline.rb
        pipeline_step.rb
        pipeline_run.rb
        image_candidate.rb
      commands/
        record_vote.rb
        reject_image_branch.rb
  
  job_orchestration/  # Intelligent job selection
    app/
      commands/
        select_next_job.rb
        build_job_payload.rb
  
  comfyui/            # ComfyUI API integration
    app/
      models/
        comfyui_job.rb
      services/
        comfyui_client.rb
      commands/
        submit_job.rb
        poll_job_status.rb
        process_job_result.rb
      workers/
        job_submitter_worker.rb
        job_poller_worker.rb
```


## Current Status

### ✅ Complete Implementation

All core functionality is implemented and tested. The system can autonomously:
1. Select optimal jobs using ELO-weighted algorithm
2. Submit jobs to ComfyUI API
3. Poll for job completion
4. Download and save results
5. Create new ImageCandidates in the tree structure
6. Repeat continuously via background workers

### Implemented Features

**Persona Management** ✅
- CRUD operations for personas
- Caption config (JSONB) for AI generation preferences
- Hashtag strategy (JSONB) for hashtag selection
- Content pillars with weights and priorities
- Persona-scoped photo library
- Comprehensive dashboard view

**Content Strategy** ✅
- Content pillars with weight-based distribution
- Priority levels (1-5) for scheduling preference
- Seasonal pillars with date ranges (start_date, end_date)
- Active/inactive status per pillar
- Gap analysis identifying under-represented content
- Visual gap indicators (red = urgent, green = satisfied)
- Photo organization by pillar

**AI Image Generation Pipeline** ✅
- Multi-stage ComfyUI workflow execution
- Template-based pipeline definitions with variable substitution
- Per-parent breadth-first job selection
- Round-robin run selection across multiple active runs
- ELO-weighted candidate prioritization
- Tree structure for managing image candidates
- Autonomous background workers (Sidekiq)
- ComfyUI API integration with retry logic
- State tracking: pending → submitted → running → completed/failed

**Image Voting & Curation** ✅
- ELO-based A vs B voting interface
- Per-run voting scoped to individual pipeline executions
- Gallery views with per-step filtering
- Approval gates for multi-step pipelines
- Winner selection with persistent flag
- Branch rejection (kill failed branches)
- Secure image serving through Rails
- Live updates via Turbo Streams

**AI Caption & Hashtag Generation** ✅
- Google Gemini API integration
- Context-aware caption generation using persona config
- Pillar-specific prompt generation
- Hashtag suggestions based on persona strategy
- Manual caption editing and approval
- Caption regeneration on demand

**Instagram Scheduling & Posting** ✅
- Instagram Graph API integration
- Draft → Scheduled → Posted workflow
- Visual post creation interface
- Automatic caption generation during post creation
- Scheduled posting via cron jobs (hourly)
- Manual immediate posting option
- Post status tracking with error handling
- Provider post ID tracking for analytics
- Failed post retry capability

**Web Interface** ✅
- Dashboard with persona overview and stats
- Persona show page with pillars, gaps, and content
- Content pillar management (create/edit/delete)
- Gap analysis visualization with color coding
- Run monitoring with live Turbo Stream updates
- Per-run voting, gallery, and winners pages
- Post scheduling calendar interface
- Photo browsing and selection
- Dark theme with Tailwind CSS v4
- Mobile-responsive design

**Developer Tools** ✅
- Rake tasks for pipeline setup
- Comprehensive documentation (the four doc homes: ARCHITECTURE, CONTRACTS, OPS, DESIGN)
- Packwerk pack structure with enforced boundaries
- RSpec test suite with FactoryBot
- GLCommand pattern with transaction safety

### Test Coverage

- **Comprehensive RSpec test suite** across all packs
- Pipeline pack: Model, command, and voting tests
- Job Orchestration: Job selection and payload building
- ComfyUI Integration: API client and worker tests
- Personas: Persona and pillar management tests
- Content Strategy: Gap analysis and post selection tests
- Scheduling: Post creation and Instagram integration tests
- Caption Generation: AI caption and hashtag tests
- Request specs: Controller integration tests
- 100% Packwerk compliance with enforced boundaries

## Development

### Pre-commit Validation

Run the full validation suite before committing:

```bash
bin/rspec --fail-fast && bin/packwerk check && bin/packwerk validate && bundle exec rubocop --fail-fast
```


## Development Conventions

See `docs/CONVENTIONS.md` for full details:

- **No controller specs** - Use request specs for HTTP testing
- **GLCommand pattern** - Isolate business logic with rollback support
- **Isolated unit tests** - Mock external dependencies
- **State machines** - Use `state_machines-activerecord` for status fields
- **ViewComponents** - All UI components with preview files
- **Packwerk** - Enforce domain boundaries
- **Safe migrations** - Schema-only migrations, separate data tasks


## Project Documentation

The documentation index and status rules live in `docs/README.md`. The four root doc homes:

- `ARCHITECTURE.md` — the app's structure: stack, pack boundaries, the command rail, the render
  pipeline, the brain seat, the growth harness, the data spine.
- `CONTRACTS.md` — the behavioral and data contracts: the legal floor, each gate's contract, the
  command/state-machine contracts, the claim contract, the agent test-signal contract, the
  attribution spine.
- `OPS.md` — operations: the `bin/verify` gate, the honest `bin/*.sh` + `bin/*.py` command
  inventory, the cron fleet, the GPU claim lifecycle, the ComfyUI and brain runbooks, deploy.
- `DESIGN.md` — the app UI design system: Tailwind v4 tokens, the ViewComponent library,
  navigation, the lookbook.

Other current docs: `docs/PROJECT_PLAN.md` (the spine), `docs/strategy-v2.md` (distribution
diagnosis), `docs/experiment-backlog.md` (the experiment lane), `docs/baseline-config.md` (the
validated render configuration), `THESIS.md`, `FOUNDERS.md`, `AGENTS.md`.

Superseded and historical documents (the pre-rebuild guides, the Catalyst/integration reports, the
archived design-system docs) live under `docs/archive/`.


## Testing

```bash
# Run all tests
bin/rspec

# Run specific pack tests
bin/rspec packs/pipeline/spec/

# Run specific file
bin/rspec spec/models/pipeline_spec.rb
```

Tests use:
- RSpec with shoulda-matchers
- FactoryBot for test data (automatically loads from packs)
- N+1 query detection with n_plus_one_control


## License

[To be determined]