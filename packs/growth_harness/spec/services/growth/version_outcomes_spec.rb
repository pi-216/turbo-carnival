# frozen_string_literal: true

require "rails_helper"

# #40 criterion 3: "two versions' outcomes are comparable by query". The comparison is a read
# over the spine -- no hand-kept version->asset table, and no re-deriving the render -> post
# chain that `Growth::RenderReach` already owns.
RSpec.describe Growth::VersionOutcomes do
  let(:persona) { create(:persona, name: "Sarah") }
  let(:pillar) { create(:content_pillar, persona: persona) }

  def version_with(checkpoint:)
    Attribution::RecordContentConfigVersion.call(
      prompt_parts: { identity: "sarah1a3, slender", scene: "sunlit bedroom" },
      checkpoint: checkpoint, wardrobe_level: 2
    ).version
  end

  def render_for(version, candidate)
    create(:attribution_render, image_candidate: candidate, content_config_version: version)
  end

  # post -> photo -> candidate -> render, the same chain `RenderReach` walks.
  def publish(render, reach:, views: nil, status: "posted")
    photo = ContentPillars::Photo.create!(persona: persona, content_pillar: pillar,
                                          path: "spec-#{SecureRandom.hex(4)}.png",
                                          image_candidate: render.image_candidate)
    Scheduling::Post.create!(persona: persona, photo: photo, caption: "a real caption",
                             status: status, posted_at: 2.days.ago,
                             provider_post_id: "ig-#{SecureRandom.hex(6)}",
                             reach: reach, views: views)
  end

  def row_for(rows, version)
    rows.find { |row| row.version_id == version.id }
  end

  it "answers the outcome of each version side by side" do
    old = version_with(checkpoint: "CRPv18_PM25.safetensors")
    new = version_with(checkpoint: "CRPv20_PM25.safetensors")

    publish(render_for(old, create(:image_candidate)), reach: 6, views: 11)
    publish(render_for(new, create(:image_candidate)), reach: 40, views: 61)

    rows = described_class.call

    expect(row_for(rows, old).reach).to eq(6)
    expect(row_for(rows, new).reach).to eq(40)
    expect(row_for(rows, old).digest).to eq(old.digest)
    expect(row_for(rows, new).render_count).to eq(1)
    expect(row_for(rows, new).post_count).to eq(1)
  end

  it "groups every render of a version under that version" do
    version = version_with(checkpoint: "CRPv18_PM25.safetensors")

    publish(render_for(version, create(:image_candidate)), reach: 5)
    publish(render_for(version, create(:image_candidate)), reach: 7)

    row = row_for(described_class.call, version)

    expect(row.render_count).to eq(2)
    expect(row.post_count).to eq(2)
    expect(row.reach).to eq(12)
  end

  # The red line at the query: unmeasured is not zero. A version whose posts carry no reach yet
  # reports NULL -- 0 would read as "this config earned nothing".
  it "reports a version with no measured reach as NULL, never 0" do
    version = version_with(checkpoint: "CRPv18_PM25.safetensors")
    publish(render_for(version, create(:image_candidate)), reach: nil)

    row = row_for(described_class.call, version)

    expect(row.reach).to be_nil
    expect(row.reach).not_to eq(0)
    expect(row.render_count).to eq(1)
  end

  it "reports a version that has never been rendered as zero renders with NULL reach" do
    version = version_with(checkpoint: "CRPv18_PM25.safetensors")

    row = row_for(described_class.call, version)

    expect(row.render_count).to eq(0)
    expect(row.reach).to be_nil
  end

  # A render that predates the spine references no version and must not be attributed to one.
  it "attributes nothing to a render with no version" do
    create(:attribution_render, image_candidate: create(:image_candidate), content_config_version: nil)
    version = version_with(checkpoint: "CRPv18_PM25.safetensors")

    expect(row_for(described_class.call, version).render_count).to eq(0)
  end
end
