class ImageCandidatesController < ApplicationController
  before_action :set_image_candidate

  def select_winner
    @image_candidate.mark_as_winner!
    redirect_back fallback_location: root_path, notice: "Winner selected!"
  end

  def unselect_winner
    @image_candidate.unmark_as_winner!
    redirect_back fallback_location: root_path, notice: "Winner unselected."
  end

  private

  def set_image_candidate
    @image_candidate = ImageCandidate.find(params[:id])
  end
end
