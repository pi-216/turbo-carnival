class RunsController < ApplicationController
  def index
    @active_runs = PipelineRun.includes(:pipeline)
                              .where(status: [ "pending", "running" ])
                              .order(created_at: :desc)
                              .page(params[:active_page])
                              .per(10)

    @completed_runs = PipelineRun.includes(:pipeline)
                                 .where(status: "completed")
                                 .order(created_at: :desc)
                                 .page(params[:completed_page])
                                 .per(20)

    @pipelines = Pipeline.order(:name)
  end

  def new
    @pipelines = Pipeline.order(:name)
    @personas = Persona.order(:name)
    @pillars = ContentPillar.order(:name)
    @run = PipelineRun.new

    # Pre-select persona/pillar if coming from pillar page
    if params[:content_pillar_id].present?
      pillar = ContentPillar.find(params[:content_pillar_id])
      @run.content_pillar = pillar
      @run.persona = pillar.persona
    elsif params[:persona_id].present?
      @run.persona = Persona.find(params[:persona_id])
    end
  end

  def create
    result = CreatePipelineRun.call(
      pipeline_id: run_params[:pipeline_id],
      name: run_params[:name],
      prompt: run_params[:prompt],
      target_folder: run_params[:target_folder],
      persona_id: run_params[:persona_id],
      content_pillar_id: run_params[:content_pillar_id],
      variables: parse_variables(run_params[:variables])
    )

    if result.success?
      redirect_to run_path(result.run), notice: "Run '#{result.run.name}' created successfully"
    else
      @pipelines = Pipeline.order(:name)
      @personas = Persona.order(:name)
      @run = PipelineRun.new(run_params.except(:variables))
      @variables_json = run_params[:variables]
      flash.now[:alert] = result.full_error_message || "Failed to create run"
      render :new, status: :unprocessable_entity
    end
  end

  def show
    @run = PipelineRun.find(params[:id])
    @pipeline = @run.pipeline

    # Build tree structure starting from step 1
    first_step = @pipeline.pipeline_steps.order(:order).first
    @root_candidates = ImageCandidate.where(
      pipeline_step: first_step,
      pipeline_run: @run,
      status: "active"
    ).order(elo_score: :desc)

    # Get all steps for navigation
    @steps = @pipeline.pipeline_steps.order(:order)

    # Calculate overall stats
    @total_candidates = ImageCandidate.where(pipeline_run: @run, status: "active").count
    @total_rejected = ImageCandidate.where(pipeline_run: @run, status: "rejected").count
    @total_votes = Vote.joins(:winner).where(image_candidates: { pipeline_run_id: @run.id }).count

    # Per-step stats
    @step_stats = @steps.map do |step|
      active_count = ImageCandidate.where(
        pipeline_step: step,
        pipeline_run: @run,
        status: "active"
      ).count

      max_children = step.max_children || JobOrchestrationConfig.max_children_per_node

      # Calculate target based on parents
      if step.order == 1
        target = max_children
      else
        prev_step = @pipeline.pipeline_steps.find_by(order: step.order - 1)
        parent_count = ImageCandidate.where(
          pipeline_step: prev_step,
          pipeline_run: @run,
          status: "active"
        ).count
        target = parent_count * max_children
      end

      {
        step: step,
        active_count: active_count,
        target: target,
        complete: active_count >= target
      }
    end

    @completion_percentage = if @step_stats.size > 0
      (@step_stats.count { |s| s[:complete] }.to_f / @step_stats.size * 100).round
    else
      0
    end
  end

  def card
    @run = PipelineRun.find(params[:id])
    render partial: "run_card", locals: { run: @run }, layout: false
  end

  def winners
    @run = PipelineRun.find(params[:id])
    pipeline = @run.pipeline
    rightmost_step = pipeline.pipeline_steps.reorder(order: :desc).first

    if rightmost_step
      @winners = ImageCandidate.where(
        pipeline_step: rightmost_step,
        pipeline_run: @run,
        status: "active"
      ).order(elo_score: :desc).limit(3)

      @step = rightmost_step
    else
      @winners = []
      @step = nil
    end

    render "winners/show"
  end

  def complete
    @run = PipelineRun.find(params[:id])
    @run.update!(status: "completed")

    redirect_to runs_path, notice: "Run '#{@run.name}' marked as complete"
  end

  private

  def run_params
    params.require(:pipeline_run).permit(:pipeline_id, :name, :prompt, :target_folder, :persona_id, :content_pillar_id, :variables)
  end

  def parse_variables(variables_string)
    return {} if variables_string.blank?
    JSON.parse(variables_string)
  rescue JSON::ParserError
    {}
  end
end
