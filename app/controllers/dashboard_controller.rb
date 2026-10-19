# frozen_string_literal: true

class DashboardController < ApplicationController
  def index
    @personas = Persona.includes(:content_pillars).all
    @recent_runs = PipelineRun.order(created_at: :desc).limit(10)

    # Stats for dashboard
    @stats = {
      total_personas: Persona.count,
      total_pillars: ContentPillar.count,
      total_photos: ContentPillars::Photo.count,
      total_runs: PipelineRun.count
    }
  end
end
