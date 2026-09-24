class GapAnalysesController < ApplicationController
  before_action :set_persona
  before_action :set_gap_analysis, only: [ :show ]

  def index
    @gap_analyses = @persona.gap_analyses.recent
  end

  def show
    @content_suggestions = @gap_analysis.content_suggestions.includes(:content_pillar)
  end

  def create
    @gap_analysis = GapAnalysisService.new(@persona).analyze!

    redirect_to persona_gap_analysis_path(@persona, @gap_analysis),
                notice: "Gap analysis completed! Found #{@gap_analysis.content_suggestions.count} suggestions."
  rescue => e
    redirect_to persona_path(@persona), alert: "Error running gap analysis: #{e.message}"
  end

  private

  def set_persona
    @persona = Persona.find(params[:persona_id])
  end

  def set_gap_analysis
    @gap_analysis = @persona.gap_analyses.find(params[:id])
  end
end
