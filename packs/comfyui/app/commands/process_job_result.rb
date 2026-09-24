class ProcessJobResult < GLCommand::Callable
  requires :comfyui_job

  returns :image_candidate

  def call
    job = context.comfyui_job

    # Extract image info from result metadata
    # Structure: {"node_id" => {"images" => [{filename, subfolder, type}]}}
    # Some workflows emit multiple outputs (e.g. a text node + a SaveImage),
    # so find whichever node actually produced images.
    output_node = job.result_metadata
    image_info = nil
    output_node.each do |_node_id, payload|
      next unless payload.is_a?(Hash) && payload["images"].present?

      image_info = payload["images"].first
      break
    end

    unless image_info
      stop_and_fail!("ComfyUI run completed but produced no image output (nodes: #{job.result_metadata.keys.join(', ')})")
      return
    end

    # Build ComfyUI output path
    filename = image_info["filename"]
    subfolder = image_info["subfolder"]

    # ComfyUI saves to: /path/to/ComfyUI/output/{subfolder}/{filename}
    comfyui_output_dir = "/mnt/fscache/essdee/ComfyUI/output"
    image_path = File.join(comfyui_output_dir, subfolder, filename)

    # Create ImageCandidate
    candidate = ImageCandidate.create!(
      pipeline_step: job.pipeline_step,
      pipeline_run: job.pipeline_run,
      parent: job.parent_candidate,
      image_path: image_path,
      status: "active"
    )

    # Link the job to the created candidate
    job.update!(image_candidate: candidate)

    # Run quality assessment on step 4 (Replace Hands) — final visual output
    # Step 5 (Upscale) disabled due to missing DINO custom node
    qa_step = job.pipeline_run.pipeline.pipeline_steps.find_by(order: 4)
    if qa_step && job.pipeline_step_id == qa_step.id
      QualityAssessImage.call(image_candidate: candidate)
    end

    context.image_candidate = candidate
  end
end
