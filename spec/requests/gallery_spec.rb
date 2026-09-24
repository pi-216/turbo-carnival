require "rails_helper"

RSpec.describe "Gallery", type: :request do
  let(:pipeline) { FactoryBot.create(:pipeline) }
  let!(:pipeline_run) { FactoryBot.create(:pipeline_run, pipeline: pipeline, status: 'running') }
  let!(:step1) { FactoryBot.create(:pipeline_step, pipeline: pipeline, order: 1) }
  let!(:step2) { FactoryBot.create(:pipeline_step, pipeline: pipeline, order: 2) }

  describe "GET /gallery" do
    let!(:candidate1) { FactoryBot.create(:image_candidate, pipeline_step: step2, pipeline_run: pipeline_run, elo_score: 1200) }
    let!(:candidate2) { FactoryBot.create(:image_candidate, pipeline_step: step2, pipeline_run: pipeline_run, elo_score: 1100) }

    it "shows the gallery page" do
      get run_gallery_path(pipeline_run)

      expect(response).to have_http_status(:success)
      expect(response.body).to include("Gallery")
    end

    it "shows candidates for selected step" do
      get run_gallery_path(pipeline_run, step: 2)

      expect(response).to have_http_status(:success)
      expect(response.body).to include(candidate1.id.to_s)
      expect(response.body).to include(candidate2.id.to_s)
    end
  end

  describe "POST /gallery/reject/:id" do
    let!(:candidate) { FactoryBot.create(:image_candidate, pipeline_step: step1, pipeline_run: pipeline_run) }

    it "rejects the candidate" do
      expect {
        post run_gallery_reject_path(pipeline_run, candidate, step: 1)
      }.to change { candidate.reload.status }.from("active").to("rejected")

      expect(response).to redirect_to(run_gallery_path(pipeline_run, step: 1))
    end
  end
end
