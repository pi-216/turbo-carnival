# Pipeline Setup Guide

> **Status:** UNREVIEWED — predates the 2026-10 rebuild

This guide shows you how to create and run image generation pipelines.

## Quick Start

### 1. Create Example Pipeline

```bash
bin/rails pipeline:setup_example
```

This creates a complete 4-step portrait generation pipeline:
1. **Base Image** - Initial generation (uses prompt)
2. **Face Fix** - Face restoration (uses parent image)
3. **Hand Fix** - Hand restoration (uses parent image)  
4. **Upscale** - 4x upscale (uses both prompt and parent image)

### 2. Update Workflow JSON

Edit the pipeline steps to use your actual ComfyUI workflow JSON:

```ruby
# In Rails console or a migration
step = PipelineStep.find_by(name: "Base Image")
step.update!(
  comfy_workflow_json: File.read("path/to/your/comfyui_workflow.json")
)
```

### 3. Start the Workers

```bash
bundle exec sidekiq
```

The system will now autonomously:
- Select the next job to run (using ELO scoring)
- Submit jobs to ComfyUI
- Poll for completions
- Download and save results
- Create new ImageCandidates

## Creating Custom Pipelines

### Using Rails Console

```ruby
# Create pipeline
pipeline = Pipeline.create!(
  name: "My Custom Pipeline",
  description: "Description here"
)

# Add steps in order
step1 = pipeline.pipeline_steps.create!(
  name: "Step 1",
  order: 1,
  comfy_workflow_json: your_workflow_json,
  needs_run_prompt: true,          # Will receive the run's prompt
  needs_parent_image_path: false   # First step has no parent
)

step2 = pipeline.pipeline_steps.create!(
  name: "Step 2", 
  order: 2,
  comfy_workflow_json: your_workflow_json,
  needs_run_prompt: false,         # Doesn't need prompt
  needs_parent_image_path: true    # Needs image from step 1
)

# Create runs
run1 = pipeline.pipeline_runs.create!(
  name: "Gym Photos",
  target_folder: "/storage/runs/2025-11-10/gym",
  variables: {
    prompt: "person at the gym",
    persona_id: 123
  }
)

run2 = pipeline.pipeline_runs.create!(
  name: "Coffee Shop Photos",
  target_folder: "/storage/runs/2025-11-10/coffee",
  variables: {
    prompt: "person at a coffee shop",
    persona_id: 123
  }
)
```

### Using Rake Task

```bash
# Find your pipeline ID first
bin/rails console
> Pipeline.all.pluck(:id, :name)

# Then create a run
bin/rails pipeline:create_run[1,"Beach Shoot","person on the beach, sunset, casual clothes"]
```

## Variable Substitution

The system automatically substitutes variables in your ComfyUI workflow:

```json
{
  "workflow": {
    "prompt_node": {
      "text": "{{prompt}}"
    },
    "load_image_node": {
      "image": "{{parent_image_path}}"
    }
  }
}
```

Available variables:
- `{{prompt}}` - From `pipeline_run.variables['prompt']`
- `{{parent_image_path}}` - Path to parent candidate's image
- Any custom variable from `pipeline_run.variables`

## Autonomous Operation

Once workers are running, the system operates autonomously:

1. **SelectNextJob** chooses what to generate:
   - Prioritizes rightmost (final) steps
   - Uses ELO-weighted raffle for fairness
   - Auto-generates base images when needed

2. **BuildJobPayload** constructs the job:
   - Parses workflow JSON
   - Substitutes variables
   - Sets output folder

3. **SubmitJob** sends to ComfyUI:
   - Creates ComfyuiJob record
   - POSTs to API
   - Handles retries

4. **PollJobStatus** checks progress:
   - Queries API every 5 seconds
   - Updates job status

5. **ProcessJobResult** saves images:
   - Downloads from ComfyUI
   - Creates ImageCandidate
   - Links to parent and run
   - Ready for next step!

## Configuration

### Worker Intervals

```bash
# Set custom intervals (in seconds)
COMFYUI_SUBMIT_INTERVAL=10  # How often to submit new jobs
COMFYUI_POLL_INTERVAL=5     # How often to check job status

bundle exec sidekiq
```

### Job Selection Parameters

```bash
# Configure selection algorithm
PIPELINE_N=5   # Max children per candidate (default: 5)
PIPELINE_T=10  # Target final candidates (default: 10)

bundle exec sidekiq
```

### ComfyUI Connection

```bash
# Set ComfyUI API endpoint
COMFYUI_BASE_URL=http://localhost:8188  # Default
COMFYUI_TIMEOUT=120                      # Request timeout (seconds)
COMFYUI_MAX_RETRIES=3                    # Retry attempts

bundle exec sidekiq
```

## Monitoring

### View Pipeline Status

```ruby
# In Rails console
pipeline = Pipeline.find(1)

# See all runs
pipeline.pipeline_runs.each do |run|
  puts "#{run.name}: #{run.image_candidates.count} images"
end

# Check job queue
ComfyuiJob.in_flight.count  # Jobs being processed
ComfyuiJob.pending.count    # Waiting to submit
ComfyuiJob.completed.count  # Done

# See what's next
result = SelectNextJob.call
puts "Next: #{result.mode} - #{result.next_step.name}"
```

### Sidekiq Dashboard

Access the Sidekiq web UI (if configured) to see:
- Active jobs
- Failed jobs
- Retry queue
- Statistics

## Tips

1. **Start Small**: Create one pipeline with 2-3 steps first
2. **Test Workflows**: Verify each ComfyUI workflow works standalone
3. **Use Variables**: Keep workflows generic with `{{variables}}`
4. **Monitor Logs**: Watch `log/development.log` for activity
5. **Check Results**: Images appear in each run's `target_folder`

## Troubleshooting

### Jobs Not Submitting

Check SelectNextJob result:
```ruby
result = SelectNextJob.call
result.mode  # :no_work, :base_generation, or :child_generation
```

### ComfyUI Connection Failed

Verify settings:
```ruby
# In Rails console
client = ComfyuiClient.new
response = client.get("/queue")  # Should return queue status
```

### Images Not Saving

Check ProcessJobResult:
```ruby
job = ComfyuiJob.completed.last
ProcessJobResult.call(comfyui_job: job)
```
