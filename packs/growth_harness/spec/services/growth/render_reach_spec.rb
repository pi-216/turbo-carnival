# frozen_string_literal: true

require 'rails_helper'

# #39 criterion 2: "a query groups reach by the render that produced it with no manual
# mapping". The join IS the mapping -- nothing here reads a hand-kept table of
# render->post pairs, and nothing matches on a file path.
#
# The read is deliberately partial and says so: a post with no photo (a reel), a photo
# with no candidate, and a render with no published post are all ABSENT from the result
# rather than reported as zero. Absence is the honest answer for "not attributable".
RSpec.describe Growth::RenderReach do
  let(:persona) { create(:persona, name: 'Sarah') }
  let(:pillar) { create(:content_pillar, persona: persona) }

  def render_with(candidate)
    create(:attribution_render, image_candidate: candidate)
  end

  # post -> photo -> candidate -> render, the exact chain the query walks.
  # `photos.image_candidate_id` is unique, so one render has one photo -- which is why
  # a second post for the same render cannot be built and why the grouping is 1:1 today.
  def photo_for(render)
    ContentPillars::Photo.create!(persona: persona, content_pillar: pillar,
                                  path: "spec-#{SecureRandom.hex(4)}.png",
                                  image_candidate: render.image_candidate)
  end

  def post_for(photo, reach:, views: nil, status: 'posted')
    Scheduling::Post.create!(persona: persona, photo: photo, caption: 'a real caption',
                             status: status, posted_at: 2.days.ago,
                             provider_post_id: "ig-#{SecureRandom.hex(6)}",
                             reach: reach, views: views)
  end

  def publish(render, **attrs)
    post_for(photo_for(render), **attrs)
  end

  it 'groups reach and views by the render that produced them' do
    render = render_with(create(:image_candidate))
    publish(render, reach: 6, views: 11)

    row = described_class.call.find { |r| r.render_id == render.id }

    expect(row.post_count).to eq(1)
    expect(row.reach).to eq(6)
    expect(row.views).to eq(11)
    # The render's own axes come back with the number, so a caller can rank renders
    # ("which checkpoint earned this") without a second lookup.
    expect(row.checkpoint).to eq(render.checkpoint)
    expect(row.seed).to eq(render.seed)
  end

  # The red line, at the query: a render whose posts have no reach yet has UNKNOWN
  # reach. SUM() over an all-NULL group is NULL in SQL, and 0 would be a fabricated
  # measurement -- exactly what this ticket forbids storing.
  it 'reports a render with no measured reach as NULL, never 0' do
    render = render_with(create(:image_candidate))
    publish(render, reach: nil)

    row = described_class.call.find { |r| r.render_id == render.id }

    expect(row.reach).to be_nil
    expect(row.post_count).to eq(1)
  end

  it 'omits an unattributable post rather than inventing a row for it' do
    render = render_with(create(:image_candidate))
    publish(render, reach: 5, views: 5)
    # A reel: posted, real reach, no photo -- so no chain back to a render.
    reel = Scheduling::Post.create!(persona: persona, caption: 'a reel', status: 'posted',
                                    posted_at: 1.day.ago, provider_post_id: 'ig-reel',
                                    reach: 13, views: 16, reel_path: '/tmp/reel.mp4')

    rows = described_class.call

    expect(rows.map(&:render_id)).to eq([ render.id ])
    expect(rows.sum(&:reach)).to eq(5)  # the reel's 13 is not attributed to anyone
    expect(reel.reload.reach).to eq(13) # and it is untouched, not moved
  end

  it 'counts only published posts' do
    live = render_with(create(:image_candidate))
    publish(live, reach: 5)
    # Same chain, never published: it must not contribute reach to its render.
    unpublished = render_with(create(:image_candidate))
    post_for(photo_for(unpublished), reach: 99, status: 'draft')

    rows = described_class.call

    expect(rows.map(&:render_id)).to eq([ live.id ])
    expect(rows.sum(&:reach)).to eq(5)
  end
end
