require "rails_helper"

RSpec.describe "Images", type: :request do
  describe "GET /images/:id" do
    it "serves the image file" do
      pipeline = FactoryBot.create(:pipeline)
      step = FactoryBot.create(:pipeline_step, pipeline: pipeline, order: 1)

      # Create a temporary test image
      temp_file = Tempfile.new([ "test_image", ".png" ])
      temp_file.write("fake image data")
      temp_file.close

      candidate = FactoryBot.create(:image_candidate, pipeline_step: step, image_path: temp_file.path)

      get candidate_image_path(candidate)

      expect(response).to have_http_status(:success)
      expect(response.content_type).to eq("image/png")
      expect(response.body).to eq("fake image data")

      temp_file.unlink
    end

    it "returns 404 when image file does not exist" do
      pipeline = FactoryBot.create(:pipeline)
      step = FactoryBot.create(:pipeline_step, pipeline: pipeline, order: 1)
      candidate = FactoryBot.create(:image_candidate, pipeline_step: step, image_path: "/nonexistent/path.png")

      get candidate_image_path(candidate)

      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 when image_path is nil" do
      pipeline = FactoryBot.create(:pipeline)
      step = FactoryBot.create(:pipeline_step, pipeline: pipeline, order: 1)
      candidate = FactoryBot.create(:image_candidate, pipeline_step: step, image_path: nil)

      get candidate_image_path(candidate)

      expect(response).to have_http_status(:not_found)
    end
  end
end
