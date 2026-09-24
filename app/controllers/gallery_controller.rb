class GalleryController < ApplicationController
  before_action :load_run

  def index
    @pipeline = @run.pipeline

    # If no step specified, find the latest step with images
    if params[:step].blank?
      latest_step = @pipeline.pipeline_steps.order(order: :desc).find do |step|
        ImageCandidate.where(pipeline_step: step, status: "active", pipeline_run: @run).exists?
      end
      @selected_step = latest_step || @pipeline.pipeline_steps.order(:order).last
    else
      @selected_step = @pipeline.pipeline_steps.find_by(order: params[:step].to_i)
    end

    @candidates = ImageCandidate
      .where(pipeline_step: @selected_step, status: "active", pipeline_run: @run)
      .order(elo_score: :desc)
      .limit(50)
  end

  def approve_step
    @step = @run.pipeline.pipeline_steps.find(params[:step_id])
    top_k = params[:top_k_count].to_i

    # Validation: K must be at least 1
    if top_k < 1
      redirect_to run_gallery_path(@run, step: @step.order), alert: "K must be at least 1"
      return
    end

    # Approve the step
    @run.approve_step!(@step, top_k: top_k)

    redirect_to run_gallery_path(@run, step: @step.order),
                notice: "Step #{@step.order} approved! Top #{top_k} candidates will advance."
  rescue => e
    redirect_to run_gallery_path(@run, step: @step.order),
                alert: "Failed to approve: #{e.message}"
  end

  def reject
    candidate = ImageCandidate.find(params[:id])
    RejectImageBranch.call!(image_candidate: candidate)

    redirect_to run_gallery_path(@run, step: params[:step]), notice: "Candidate rejected"
  end

  private

  def load_run
    @run = PipelineRun.find(params[:run_id])
  end
end
