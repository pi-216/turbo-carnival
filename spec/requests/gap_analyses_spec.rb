require 'rails_helper'

RSpec.describe "GapAnalyses", type: :request do
  let(:persona) { Persona.create!(name: "Test Persona") }

  describe "GET /index" do
    it "returns http success" do
      get persona_gap_analyses_path(persona)
      expect(response).to have_http_status(:success)
    end
  end

  describe "GET /show" do
    it "returns http success" do
      gap_analysis = GapAnalysis.create!(
        persona: persona,
        analyzed_at: Time.current,
        coverage_data: []
      )
      get persona_gap_analysis_path(persona, gap_analysis)
      expect(response).to have_http_status(:success)
    end
  end

  describe "POST /create" do
    it "returns http redirect" do
      post persona_gap_analyses_path(persona)
      expect(response).to have_http_status(:redirect)
    end
  end
end
