class RedirectsController < ApplicationController
  def vote
    first_run = PipelineRun.where.not(status: "completed").order(:id).first

    if first_run
      redirect_to run_vote_path(first_run)
    else
      redirect_to runs_path, alert: "No active runs available"
    end
  end

  def gallery
    first_run = PipelineRun.where.not(status: "completed").order(:id).first

    if first_run
      redirect_to run_gallery_path(first_run)
    else
      redirect_to runs_path, alert: "No active runs available"
    end
  end
end
