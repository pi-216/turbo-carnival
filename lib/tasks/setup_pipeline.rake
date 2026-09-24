namespace :pipeline do
  desc "Create a sample portrait generation pipeline"
  task setup_example: :environment do
    puts "Creating Portrait Generation Pipeline..."

    pipeline = Pipeline.create!(
      name: "Portrait Generation",
      description: "Multi-stage portrait generation with face fix, hand fix, and upscaling"
    )

    puts "✓ Created pipeline: #{pipeline.name}"

    # Step 1: Base Image Generation
    step1 = pipeline.pipeline_steps.create!(
      name: "Base Image",
      order: 1,
      comfy_workflow_json: {
        "workflow": "base_generation",
        "nodes": {
          "sampler": "euler",
          "steps": 20,
          "cfg": 7
        }
      }.to_json,
      needs_run_prompt: true,
      needs_parent_image_path: false
    )
    puts "✓ Created step #{step1.order}: #{step1.name}"

    # Step 2: Face Fix
    step2 = pipeline.pipeline_steps.create!(
      name: "Face Fix",
      order: 2,
      comfy_workflow_json: {
        "workflow": "face_restoration",
        "models": [ "CodeFormer", "GFPGAN" ]
      }.to_json,
      needs_run_prompt: false,
      needs_parent_image_path: true
    )
    puts "✓ Created step #{step2.order}: #{step2.name}"

    # Step 3: Hand Fix
    step3 = pipeline.pipeline_steps.create!(
      name: "Hand Fix",
      order: 3,
      comfy_workflow_json: {
        "workflow": "hand_restoration",
        "inpainting": true
      }.to_json,
      needs_run_prompt: false,
      needs_parent_image_path: true
    )
    puts "✓ Created step #{step3.order}: #{step3.name}"

    # Step 4: Upscale
    step4 = pipeline.pipeline_steps.create!(
      name: "Upscale",
      order: 4,
      comfy_workflow_json: {
        "workflow": "upscale",
        "upscaler": "RealESRGAN_x4plus",
        "scale_factor": 4
      }.to_json,
      needs_run_prompt: true,
      needs_parent_image_path: true
    )
    puts "✓ Created step #{step4.order}: #{step4.name}"

    # Create sample pipeline run
    run = pipeline.pipeline_runs.create!(
      name: "Gym Shoot",
      target_folder: "/storage/runs/#{Date.today}/gym-shoot",
      variables: {
        prompt: "professional photo of a person at the gym, athletic wear, motivated expression",
        persona_id: 1,
        style: "photorealistic"
      }
    )
    puts "✓ Created sample run: #{run.name}"

    puts "\n=== Pipeline Setup Complete ==="
    puts "Pipeline ID: #{pipeline.id}"
    puts "Steps: #{pipeline.pipeline_steps.count}"
    puts "Runs: #{pipeline.pipeline_runs.count}"
    puts "\nNext: Update ComfyUI workflow JSON with your actual workflows"
    puts "Then start workers: bundle exec sidekiq"
  end

  desc "Create a new pipeline run"
  task :create_run, [ :pipeline_id, :name, :prompt ] => :environment do |_t, args|
    pipeline = Pipeline.find(args[:pipeline_id])

    run = pipeline.pipeline_runs.create!(
      name: args[:name],
      target_folder: "/storage/runs/#{Date.today}/#{args[:name].parameterize}",
      variables: {
        prompt: args[:prompt],
        persona_id: 1
      }
    )

    puts "✓ Created pipeline run: #{run.name}"
    puts "  Folder: #{run.target_folder}"
    puts "  Prompt: #{run.variables['prompt']}"
  end
end
