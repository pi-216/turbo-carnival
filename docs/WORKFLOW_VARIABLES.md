# Workflow Variables Guide

> **Status:** UNREVIEWED — predates the 2026-10 rebuild

This guide explains how to use variables in ComfyUI workflow JSON files.

## Overview

Variables in workflow JSON files are replaced at job submission time. There are two types of variable substitution:

1. **Template Variables** - Replaced directly in the JSON using `{{variable_name}}` syntax
2. **Runtime Variables** - Passed in the `variables` section of the job payload

## Template Variables ({{...}} syntax)

Template variables are replaced **before** the JSON is parsed, so they can be used anywhere in the workflow JSON.

### Available Template Variables

#### From PipelineRun.variables

Any key in the `PipelineRun.variables` hash can be used:
- `{{prompt}}` - The main generation prompt
- `{{run_name}}` - Name of the pipeline run
- Any custom variables you add to the PipelineRun

Example PipelineRun.variables:
```json
{
  "prompt": "A beautiful landscape",
  "run_name": "nature_photos",
  "custom_var": "some_value"
}
```

#### System Variables (automatically added)

- `{{timestamp}}` - Current Unix timestamp (seconds): `1699564800`
- `{{timestamp_ms}}` - Current Unix timestamp (milliseconds): `1699564800123`
- `{{random}}` - Random number between 0 and 999,999,999
- `{{auto_seed}}` - Auto-incrementing seed: `base_seed + job_id`
  - Base seed from `pipeline_run.variables["seed"]` (defaults to 1,000,000)
  - Ensures each job gets a unique but deterministic seed
  - Example: If base_seed=1000000 and job_id=42, auto_seed=1000042

### Usage Example

```json
{
  "107": {
    "inputs": {
      "seed": "{{random}}"
    },
    "class_type": "Seed"
  },
  "121": {
    "inputs": {
      "text": "{{prompt}}"
    },
    "class_type": "Text Multiline"
  }
}
```

## Runtime Variables (payload.variables)

Runtime variables are controlled by flags on the PipelineStep model:

### PipelineStep Flags

1. **needs_run_prompt** (boolean)
   - When true: Adds `prompt` to the payload variables
   - Source: `pipeline_run.variables["prompt"]`

2. **needs_parent_image_path** (boolean)
   - When true: Adds `parent_image` to the payload variables
   - Source: `parent_candidate.image_path`
   - Only available for child generation (steps after the first)

3. **needs_run_variables** (boolean)
   - When true: Adds ALL `pipeline_run.variables` to the payload
   - Merges all variables from the PipelineRun

### Setting Flags

```ruby
step = PipelineStep.create!(
  pipeline: pipeline,
  name: "Base Image",
  order: 1,
  comfy_workflow_json: workflow_json,
  needs_run_prompt: true,          # Add prompt to variables
  needs_parent_image_path: false,  # Not needed for first step
  needs_run_variables: true        # Add all run variables
)
```

## Complete Example

### PipelineRun Setup

```ruby
run = PipelineRun.create!(
  pipeline: pipeline,
  variables: {
    "prompt" => "A serene mountain landscape",
    "run_name" => "mountains",
    "style" => "photorealistic"
  },
  target_folder: "public/outputs/mountains"
)
```

### PipelineStep with Workflow JSON

```ruby
workflow_json = {
  "nodes": {
    "1": {
      "inputs": {
        "seed": "{{random}}",
        "text": "{{prompt}}, {{style}}"
      },
      "class_type": "KSampler"
    }
  }
}.to_json

step = PipelineStep.create!(
  pipeline: pipeline,
  name: "Generate",
  order: 1,
  comfy_workflow_json: workflow_json,
  needs_run_variables: true
)
```

### Resulting Job Payload

When the job is built, the payload will be:

```ruby
{
  workflow: {
    "nodes": {
      "1": {
        "inputs": {
          "seed": "847392847",  # Random number
          "text": "A serene mountain landscape, photorealistic"  # Substituted
        },
        "class_type": "KSampler"
      }
    }
  },
  variables: {
    prompt: "A serene mountain landscape",
    run_name: "mountains",
    style: "photorealistic"
  },
  output_folder: "public/outputs/mountains/generate"
}
```

## Variable Precedence & Processing Order

1. **Template substitution first**: All `{{variable}}` placeholders are replaced
2. **JSON parsing**: The modified string is parsed into JSON
3. **Runtime variables added**: Based on PipelineStep flags

## Common Patterns

### Auto-incrementing Seeds

```json
{
  "seed_node": {
    "inputs": {
      "seed": "{{auto_seed}}"
    }
  }
}
```

This creates deterministic but unique seeds: `base_seed + job_id`. Set the base seed in PipelineRun:

```ruby
PipelineRun.create!(
  variables: {
    "seed" => 5000000,  # Base seed
    "prompt" => "..."
  }
)
```

Or use fully random seeds:

```json
{
  "seed_node": {
    "inputs": {
      "seed": "{{timestamp_ms}}"
    }
  }
}
```

### Parent Image Loading (for refinement steps)

```ruby
# Second step in pipeline
step2 = PipelineStep.create!(
  name: "Refine",
  order: 2,
  needs_parent_image_path: true,
  comfy_workflow_json: {
    "load_image": {
      "inputs": {
        "image": "{{parent_image}}"  # Will be filled from variables
      }
    }
  }.to_json
)
```

### Dynamic Output Naming

```json
{
  "save_node": {
    "inputs": {
      "filename_prefix": "{{run_name}}/output_{{timestamp}}"
    },
    "class_type": "SaveImage"
  }
}
```

## Debugging

To see what variables are available, check:

```ruby
# In Rails console
run = PipelineRun.last
puts run.variables.inspect

step = PipelineStep.last
puts "needs_run_prompt: #{step.needs_run_prompt}"
puts "needs_parent_image_path: #{step.needs_parent_image_path}"
puts "needs_run_variables: #{step.needs_run_variables}"

# To see the actual payload that will be sent:
result = BuildJobPayload.call(
  pipeline_step: step,
  pipeline_run: run,
  parent_candidate: nil  # or an ImageCandidate for child generation
)
puts result.job_payload.inspect
```

## Best Practices

1. Use `{{random}}` or `{{timestamp_ms}}` for seeds to ensure variation
2. Set `needs_run_variables: true` if you want all run variables available
3. Use `needs_parent_image_path: true` only for steps that process parent images
4. Keep variable names simple and descriptive
5. Test your workflow JSON substitution with `BuildJobPayload` before deploying
