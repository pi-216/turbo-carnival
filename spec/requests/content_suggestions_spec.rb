require 'rails_helper'

RSpec.describe "ContentSuggestions", type: :request do
  describe "GET /index" do
    let(:persona) { FactoryBot.create(:persona) }

    it "returns a successful response and displays content suggestions" do
      # Create a GapAnalysis and ContentSuggestion associated with the persona
      gap_analysis = FactoryBot.create(:gap_analysis, persona: persona)
      content_pillar = FactoryBot.create(:content_pillar, persona: persona)
      content_suggestion = FactoryBot.create(:content_suggestion, gap_analysis: gap_analysis, content_pillar: content_pillar, title: "Test Suggestion", status: 'pending')

      get persona_content_suggestions_path(persona)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Content Suggestions")
      expect(response.body).to include("Test Suggestion")
    end

    it "handles persona not found" do
      get persona_content_suggestions_path(99999) # Non-existent persona ID
      expect(response).to have_http_status(:not_found)
    end
  end
end
