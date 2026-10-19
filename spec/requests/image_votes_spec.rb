require "rails_helper"

RSpec.describe "ImageVotes", type: :request do
  let(:pipeline) { FactoryBot.create(:pipeline) }
  let!(:pipeline_run) { FactoryBot.create(:pipeline_run, pipeline: pipeline, status: 'running') }

  describe "GET /vote" do
    context "when pairs exist" do
      it "renders the voting interface" do
        step = FactoryBot.create(:pipeline_step, pipeline: pipeline, order: 1)
        FactoryBot.create(:image_candidate, pipeline_step: step, pipeline_run: pipeline_run)
        FactoryBot.create(:image_candidate, pipeline_step: step, pipeline_run: pipeline_run)

        get run_vote_path(pipeline_run)

        expect(response).to have_http_status(:success)
        expect(response.body).to include("Vote for the Better Image")
      end
    end

    context "when no pairs exist" do
      it "shows completion message" do
        get run_vote_path(pipeline_run)

        expect(response).to have_http_status(:success)
        expect(response.body).to include("All Done")
      end
    end
  end

  describe "POST /vote" do
    it "records the vote and redirects" do
      step = FactoryBot.create(:pipeline_step, pipeline: pipeline, order: 1)
      winner = FactoryBot.create(:image_candidate, pipeline_step: step, pipeline_run: pipeline_run, elo_score: 1000)
      loser = FactoryBot.create(:image_candidate, pipeline_step: step, pipeline_run: pipeline_run, elo_score: 1000)

      post run_vote_path(pipeline_run), params: { winner_id: winner.id, loser_id: loser.id }

      expect(response).to have_http_status(:redirect)
      expect(response).to redirect_to(run_vote_path(pipeline_run))
      expect(winner.reload.elo_score).to eq(1016)
      expect(loser.reload.elo_score).to eq(984)
    end

    it "calls RecordVote command" do
      step = FactoryBot.create(:pipeline_step, pipeline: pipeline, order: 1)
      winner = FactoryBot.create(:image_candidate, pipeline_step: step, pipeline_run: pipeline_run)
      loser = FactoryBot.create(:image_candidate, pipeline_step: step, pipeline_run: pipeline_run)

      expect(RecordVote).to receive(:call!).with(winner: winner, loser: loser)

      post run_vote_path(pipeline_run), params: { winner_id: winner.id, loser_id: loser.id }
    end
  end

  describe "POST /vote/reject/:id" do
    it "rejects the candidate" do
      step = FactoryBot.create(:pipeline_step, pipeline: pipeline, order: 1)
      candidate = FactoryBot.create(:image_candidate, pipeline_step: step, pipeline_run: pipeline_run, status: "active")

      post run_reject_vote_path(pipeline_run, candidate)

      expect(response).to have_http_status(:redirect)
      expect(candidate.reload.status).to eq("rejected")
    end

    it "calls RejectImageBranch command" do
      step = FactoryBot.create(:pipeline_step, pipeline: pipeline, order: 1)
      candidate = FactoryBot.create(:image_candidate, pipeline_step: step, pipeline_run: pipeline_run)

      expect(RejectImageBranch).to receive(:call!).with(image_candidate: candidate).and_call_original

      post run_reject_vote_path(pipeline_run, candidate)
    end
  end
end
