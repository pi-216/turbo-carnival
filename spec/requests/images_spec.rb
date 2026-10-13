require "rails_helper"

RSpec.describe "Images", type: :request do
  # image_path is served only after the controller proves it stays inside the
  # ComfyUI output roots (Brakeman SendFile/Medium 3.x). COMFYUI_MIRROR_ROOT is
  # one of those roots, so the fixture lives there rather than system /tmp.
  around do |example|
    Dir.mktmpdir("image-root") do |dir|
      @mirror_root = dir
      old = ENV["COMFYUI_MIRROR_ROOT"]
      ENV["COMFYUI_MIRROR_ROOT"] = dir
      example.run
      old.nil? ? ENV.delete("COMFYUI_MIRROR_ROOT") : ENV["COMFYUI_MIRROR_ROOT"] = old
    end
  end

  attr_reader :mirror_root

  describe "GET /images/:id" do
    it "serves the image file" do
      pipeline = FactoryBot.create(:pipeline)
      step = FactoryBot.create(:pipeline_step, pipeline: pipeline, order: 1)

      # Create a temporary test image inside the serving root
      temp_path = File.join(mirror_root, "test_image.png")
      File.write(temp_path, "fake image data")

      candidate = FactoryBot.create(:image_candidate, pipeline_step: step, image_path: temp_path)

      get candidate_image_path(candidate)

      expect(response).to have_http_status(:success)
      expect(response.content_type).to eq("image/png")
      expect(response.body).to eq("fake image data")
    ensure
      FileUtils.rm_f(temp_path)
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

    it "returns 404 when image_path resolves outside the serving roots" do
      pipeline = FactoryBot.create(:pipeline)
      step = FactoryBot.create(:pipeline_step, pipeline: pipeline, order: 1)
      # A path that exists on disk but is NOT inside a serving root
      candidate = FactoryBot.create(:image_candidate, pipeline_step: step, image_path: File.expand_path("Gemfile", Rails.root))

      get candidate_image_path(candidate)

      expect(response).to have_http_status(:not_found)
    end
  end
end
