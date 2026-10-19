# frozen_string_literal: true

require "rails_helper"

# Success criterion 3 of #37: existing rows are untouched, and their absent attribution reads
# as NULL.
#
# The corpus predates this spine -- hundreds of posts and thousands of image candidates were
# produced with their inputs never recorded. A GUESSED checkpoint is worse than an absent one,
# because it silently poisons every later query, so this file asserts ABSENCE: nothing was
# backfilled, nothing was inferred, and nothing was defaulted to fill a provenance gap.
#
# It lives in the ROOT spec package rather than in packs/attribution/spec because it compares
# the spine against packs it does not depend on (photos, image candidates, posts). The root
# package has dependency enforcement off; a pack-local copy would trade the attribution pack's
# clean boundary for nothing. Precedent: spec/models/content_pillars_photo_provenance_spec.rb.
RSpec.describe "legacy rows through the attribution spine", type: :model do
  let(:persona) { create(:persona) }
  let(:pillar) { create(:content_pillar, persona: persona) }
  let(:legacy_path) { "/mnt/nas-ai-models/comfyui/output/legacy/#{SecureRandom.hex(6)}.png" }

  it "records nothing for a post that predates the spine" do
    create(:pipeline_run, persona: persona,
           variables: { "checkpoint" => "CRPv18_PM25.safetensors", "seed" => 4242 })
    photo = ContentPillars::Photo.create!(persona: persona, content_pillar: pillar, path: legacy_path)

    expect(Attribution::Asset.count).to eq(0)
    expect(Attribution::Render.count).to eq(0)
    expect(Attribution::Asset.for_path(photo.path)).to be_nil
    expect(Attribution::Render.joins(:asset).where(assets: { path: legacy_path })).to be_empty
  end

  it "does not promote a run's blob into the spine as though it were recorded inputs" do
    run = create(:pipeline_run, persona: persona,
                 variables: { "checkpoint" => "CRPv18_PM25.safetensors", "seed" => 4242 })

    # The blob keeps exactly what it always held, and the spine stays empty rather than
    # lifting a jsonb key into a column whose provenance a later reader would trust.
    expect(run.reload.variables["checkpoint"]).to eq("CRPv18_PM25.safetensors")
    expect(Attribution::Render.where(checkpoint: "CRPv18_PM25.safetensors")).to be_empty
    expect(Attribution::Render.where(seed: 4242)).to be_empty
  end

  it "leaves the pre-existing tables whole -- the migration is additive" do
    expect(ContentPillars::Photo.column_names).to include("path", "provenance", "synthetic")
    expect(PipelineRun.column_names).to include("variables", "prompt", "quality_metrics")
    expect(ImageCandidate.column_names).to include("image_path", "elo_score", "winner", "vote_count")
    expect(Scheduling::Post.column_names).to include("photo_id", "pipeline_run_id", "reach")
  end
end
