class WinnersController < ApplicationController
  before_action :load_run, only: [ :show ]

  def index
    # Show all runs with their top candidates
    @runs = PipelineRun.includes(:pipeline).order(created_at: :desc)
  end

  def show
    # Show top 3 winners for a specific run
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
  end

  private

  def load_run
    @run = PipelineRun.find(params[:id])
  end
end
