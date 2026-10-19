class CreatePipelineRun < GLCommand::Callable
  requires :pipeline_id
  allows :name, :target_folder, :variables, :prompt, :persona_id, :content_pillar_id
  returns :run

  def call
    pipeline = Pipeline.find_by(id: context.pipeline_id)
    stop_and_fail!("Pipeline not found") unless pipeline

    run_name = context.name.presence || generate_default_name(pipeline)
    folder = context.target_folder.presence || generate_target_folder(run_name)
    vars = context.variables.presence || {}

    context.run = PipelineRun.create!(
      pipeline: pipeline,
      name: run_name,
      prompt: context.prompt,
      target_folder: folder,
      variables: vars,
      persona_id: context.persona_id,
      content_pillar_id: context.content_pillar_id,
      status: "pending"
    )
  end

  def rollback
    context.run&.destroy
  end

  private

  def generate_default_name(pipeline)
    timestamp = Time.current.strftime("%Y%m%d-%H%M%S")
    "#{pipeline.name} - #{timestamp}"
  end

  def generate_target_folder(run_name)
    sanitized = run_name.parameterize
    timestamp = Time.current.strftime("%Y%m%d-%H%M%S")
    "/storage/runs/#{sanitized}-#{timestamp}"
  end
end
