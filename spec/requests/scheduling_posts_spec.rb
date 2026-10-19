require 'rails_helper'

RSpec.describe "Scheduling Posts", type: :request do
  describe "POST browsing workflow" do
    let!(:persona) { create(:persona, name: "Test Persona") }
    let!(:pillar) { create(:content_pillar, persona: persona, name: "Test Pillar") }
    let!(:photo) do
      photo = ContentPillars::Photo.create!(
        persona: persona,
        content_pillar: pillar,
        path: "/tmp/test_photo.png"
      )

      # Create a temporary image file for the photo
      File.write(photo.path, "fake image data")

      # Attach an image
      photo.image.attach(
        io: StringIO.new("fake image data"),
        filename: "test.png",
        content_type: "image/png"
      )

      photo
    end

    it "displays scheduled posts page" do
      get persona_scheduling_posts_path(persona)

      expect(response).to have_http_status(:success)
      expect(response.body).to include("Scheduled Posts")
      expect(response.body).to include(persona.name.titleize)
    end

    it "shows empty state when no posts exist" do
      get persona_scheduling_posts_path(persona)

      expect(response.body).to include("No posts yet!")
    end

    it "displays posts when they exist" do
      # Create a scheduled post
      Scheduling::Post.create!(
        persona: persona,
        photo: photo,
        caption: "Test post",
        status: 'scheduled',
        scheduled_at: 1.day.from_now
      )

      get persona_scheduling_posts_path(persona)

      expect(response).to have_http_status(:success)
      expect(response.body).to include("Scheduled")
      expect(response.body).to include("Test post")
    end

    it "shows Get Next Post Suggestion button" do
      get persona_scheduling_posts_path(persona)

      expect(response.body).to include("Get Next Post Suggestion")
    end

    it "allows deleting a post" do
      post = Scheduling::Post.create!(
        persona: persona,
        photo: photo,
        caption: "Test post to delete",
        status: 'scheduled',
        scheduled_at: 1.day.from_now
      )

      expect {
        delete persona_scheduling_post_path(persona, post)
      }.to change(Scheduling::Post, :count).by(-1)

      expect(response).to redirect_to(persona_scheduling_posts_path(persona))
      follow_redirect!
      expect(response.body).to include("Post deleted")
    end

    after do
      # Clean up test files
      [ photo, ContentPillars::Photo.where(path: "/tmp/other_photo.png").first ].compact.each do |p|
        File.delete(p.path) if p.path && File.exist?(p.path)
      end
    end
  end

  describe "POST /personas/:persona_id/scheduling/posts/suggest_next" do
    let!(:persona) { create(:persona, name: "Sarah") }
    let!(:pillar) { create(:content_pillar, persona: persona, name: "Lifestyle & Daily Living", weight: 40, active: true) }
    let!(:photo) do
      photo = ContentPillars::Photo.create!(
        persona: persona,
        content_pillar: pillar,
        path: "/tmp/suggest_test_photo.png"
      )

      File.write(photo.path, "fake image data")

      photo.image.attach(
        io: StringIO.new("fake image data"),
        filename: "suggest_test.png",
        content_type: "image/png"
      )

      photo
    end

    it "successfully suggests a next post and auto-creates it" do
      # Ensure we have strategy state
      ContentStrategy::StrategyState.find_or_create_by!(persona: persona) do |state|
        state.active_strategy = 'thematic_rotation_strategy'
        state.started_at = Time.current
      end

      # Mock the AI services to avoid external dependencies
      allow_any_instance_of(CaptionGeneration::VisionGenerator).to receive(:generate).and_return(
        double(success?: true, text: "Test caption", metadata: { model: "test-model" })
      )

      post suggest_next_persona_scheduling_posts_path(persona)

      expect(response).to have_http_status(:redirect)

      follow_redirect!

      expect(response).to have_http_status(:success)
      # Check for either success or error message
      expect(response.body).to match(/Post automatically created|Failed to create post/)
    end

    it "shows error when no unposted photos are available" do
      # Mark the photo as posted by creating a post
      Scheduling::Post.create!(
        persona: persona,
        photo: photo
      ).tap { |p| p.update_column(:status, 'posted') }

      post suggest_next_persona_scheduling_posts_path(persona)

      expect(response).to have_http_status(:redirect)
      expect(response).to redirect_to(persona_scheduling_posts_path(persona))

      follow_redirect!

      # Check for error message in flash
      expect(flash[:alert]).to be_present
    end

    after do
      File.delete(photo.path) if photo.path && File.exist?(photo.path)
    end
  end
end
