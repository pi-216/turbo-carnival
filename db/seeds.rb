pipeline = Pipeline.create!(name: 'sarah1a3')

pipeline.pipeline_steps.create!(
  name: 'Base Image',
  order: 1,
  needs_run_prompt: true,
  needs_parent_image_path: false,
  needs_run_variables: true,
  comfy_workflow_json: File.read(Rails.root.join('comfy_workflows/sarah1a3/step1_base_image.json'))
)

pipeline.pipeline_steps.create!(
  name: 'Enhance Body',
  order: 2,
  needs_run_prompt: true,
  needs_parent_image_path: true,
  needs_run_variables: true,
  comfy_workflow_json: File.read(Rails.root.join('comfy_workflows/sarah1a3/step2_body.json'))
)

pipeline.pipeline_steps.create!(
  name: 'Replace Face',
  order: 3,
  needs_run_prompt: true,
  needs_parent_image_path: true,
  needs_run_variables: true,
  comfy_workflow_json: File.read(Rails.root.join('comfy_workflows/sarah1a3/step3_face.json'))
)

pipeline.pipeline_steps.create!(
  name: 'Replace Hands',
  order: 4,
  needs_run_prompt: true,
  needs_parent_image_path: true,
  needs_run_variables: true,
  comfy_workflow_json: File.read(Rails.root.join('comfy_workflows/sarah1a3/step4_hands.json'))
)

run1 = pipeline.pipeline_runs.create!(
  name: "yoga session",
  target_folder: "public/pipeline_runs/sarah1a3/yoga_session",
  variables: {
    prompt: "**Scene:** A skinny young European woman practicing yoga in a minimalist, plant-filled apartment, holding a tree pose. **Composition:** Candid, spontaneous shot, shallow depth of field, diffused window light. **Pose:** Tree pose, serene expression. **Outfit:** Flowing ivory silk kimono, low-rise comfortable grey sweatpants, simple white sneakers, delicate gold bracelet, matching choker. A beautiful, skinny young white European woman with long, straight, brunette hair falling to her waist, framing her heart-shaped face. Her skin is creamy and flawless. She possesses large, round breasts, a tiny waist, and generous flaring hips, creating a classic hourglass figure. Her legs are long and shapely with smooth, tanned skin and a noticeable thigh gap. She has a full, rounded butt and a flat, toned stomach. Back is straight and strong, accentuating her feminine form. Her face is angelic with full lips, a small upturned nose, and large, expressive eyes. Pretty, cute, adorable. Early morning, just after sunrise, with soft, diffused light filtering through sheer linen curtains. Intentionally blurred background, creating intimacy and focus. Photography style: 50mm lens, natural light, f/2.8, 8k resolution, cinematic lighting, highly detailed, photorealistic. Muted pastel color palette – pale pinks, soft blues, warm greys. Mood: Calm, centered, gentle self-care. A skinny young white, European woman, with long, brunette hair that falls to her waist, frames her heart-shaped face. Her skin is creamy and flawless, like fresh milk. She has large, round breasts that sit high and proud, a tiny, narrow waist, and generous flaring hips, giving her a classic hourglass figure. Her legs are long and shapely, with smooth, tanned skin and delicate ankles. She  has a substantial thigh gap, a full, rounded butt with a perfect peach shape, and a flat, toned stomach with a cute belly button. Her back is straight and strong, with a graceful curve that  accentuates her feminine form. Her neck is long and slender, leading to perky breasts. Her face is angelic, with full, pouty lips, a small upturned nose, and big, expressive eyes that sparkle with innocence. Pretty, cute, adorable. She is wearing a matching choker. sarah1a3, p0k13s",
    run_name: "yoga session"
  }
)
