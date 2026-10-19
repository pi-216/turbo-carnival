require "rails_helper"

RSpec.describe "Runs", type: :request do
  describe "GET /runs" do
    it "renders the runs index" do
      get runs_path

      expect(response).to have_http_status(:success)
      expect(response.body).to include("Pipeline Runs")
    end

    it "displays existing runs" do
      pipeline = FactoryBot.create(:pipeline, name: "Test Pipeline")
      FactoryBot.create(:pipeline_step, pipeline: pipeline, order: 1)
      run = FactoryBot.create(:pipeline_run, pipeline: pipeline, name: "Test Run")

      get runs_path

      expect(response).to have_http_status(:success)
      expect(response.body).to include("Test Run")
    end
  end

  describe "GET /runs/new" do
    it "renders the new run form" do
      get new_run_path

      expect(response).to have_http_status(:success)
      expect(response.body).to include("New Pipeline Run")
    end

    it "displays available pipelines" do
      pipeline = FactoryBot.create(:pipeline, name: "Portrait Pipeline")

      get new_run_path

      expect(response).to have_http_status(:success)
      expect(response.body).to include("Portrait Pipeline")
    end
  end

  describe "POST /runs" do
    let(:pipeline) { FactoryBot.create(:pipeline, name: "Test Pipeline") }

    it "creates a new run with valid parameters" do
      expect {
        post runs_path, params: {
          pipeline_run: {
            pipeline_id: pipeline.id,
            name: "My Test Run",
            prompt: "at the gym",
            target_folder: "/storage/test",
            variables: '{"style": "cinematic"}'
          }
        }
      }.to change(PipelineRun, :count).by(1)

      expect(response).to have_http_status(:redirect)
      run = PipelineRun.last
      expect(response).to redirect_to(run_path(run))
      expect(run.name).to eq("My Test Run")
      expect(run.prompt).to eq("at the gym")
      expect(run.target_folder).to eq("/storage/test")
      expect(run.variables).to eq({ "style" => "cinematic" })
    end

    it "calls CreatePipelineRun command" do
      expect(CreatePipelineRun).to receive(:call).with(
        pipeline_id: pipeline.id.to_s,
        name: "Test Run",
        prompt: "test prompt",
        target_folder: nil,
        persona_id: nil,
        content_pillar_id: nil,
        variables: {}
      ).and_call_original

      post runs_path, params: {
        pipeline_run: {
          pipeline_id: pipeline.id,
          name: "Test Run",
          prompt: "test prompt"
        }
      }
    end

    it "creates run with auto-generated defaults" do
      post runs_path, params: {
        pipeline_run: {
          pipeline_id: pipeline.id
        }
      }

      expect(response).to have_http_status(:redirect)
      run = PipelineRun.last
      expect(run.name).to match(/Test Pipeline - \d{8}-\d{6}/)
      expect(run.target_folder).to match(%r{/storage/runs/})
    end

    it "handles invalid pipeline_id" do
      post runs_path, params: {
        pipeline_run: {
          pipeline_id: 999999,
          name: "Test Run"
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Pipeline not found")
    end

    it "re-renders form on validation errors" do
      post runs_path, params: {
        pipeline_run: {
          pipeline_id: nil,
          name: "Test Run"
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("New Pipeline Run")
    end

    it "handles invalid JSON in variables" do
      post runs_path, params: {
        pipeline_run: {
          pipeline_id: pipeline.id,
          name: "Test Run",
          prompt: "at the gym",
          variables: "invalid json"
        }
      }

      # Should still succeed but with empty variables
      expect(response).to have_http_status(:redirect)
      run = PipelineRun.last
      expect(run.prompt).to eq("at the gym")
      expect(run.variables).to eq({})
    end
  end

  describe "GET /runs/:id" do
    it "renders the run detail page" do
      pipeline = FactoryBot.create(:pipeline)
      FactoryBot.create(:pipeline_step, pipeline: pipeline, order: 1)
      run = FactoryBot.create(:pipeline_run, pipeline: pipeline)

      get run_path(run)

      expect(response).to have_http_status(:success)
    end
  end
end
