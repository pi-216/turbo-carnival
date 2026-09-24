# frozen_string_literal: true

module Personas
  class CampaignsController < ApplicationController
    before_action :set_persona

    def index
      # Find all LLM campaigns for this persona
      @campaigns = @persona.gap_analyses
        .where("recommendations @> ?", { created_by: "llm" }.to_json)
        .order(created_at: :desc)
        .includes(content_suggestions: [ :content_pillar ])
    end

    def show
      @campaign = @persona.gap_analyses.find(params[:id])
      @suggestions = @campaign.content_suggestions
        .includes(:content_pillar)
        .order(created_at: :asc)
    end

    private

    def set_persona
      @persona = Persona.find(params[:persona_id])
    end
  end
end
