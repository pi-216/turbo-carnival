# frozen_string_literal: true

require 'rails_helper'

# B5 (PRD 0007): Scheduling::Post#selection_state is the single read the public
# media endpoint uses to decide whether to serve a post's bytes. This spec pins
# the mapping that read implements, and proves the instance predicate
# (`#publicly_servable?`) and the query scope (`.publicly_servable`) agree with
# it.
#
#   :published  status :posted, or a provider post id exists
#   :queued     an unpublished post carrying a publish slot (will be / is being
#               published, so its bytes must be tunnel-reachable)
#   :held       everything else -- a HELD post (a gate cleared both publisher
#               clocks while keeping the row), a post never queued, or a failed
#               post
#
# The endpoint serves :published and :queued and 404s :held. A held fixture is
# built the way the gates build one: status kept, both clocks cleared, a hold
# marker in caption_metadata (the marker is for fidelity -- the read keys off the
# cleared clocks, not the metadata).
RSpec.describe Scheduling::Post do
  let(:persona) { create(:persona) }

  # selection_state depends only on the post's own columns, so no file is
  # touched. The fixture rows are made REELS (reel_path set) purely so the
  # photo-presence validation (`ready_to_post? && !reel?`) is bypassed -- a
  # still in a ready-to-post state would otherwise need a real photo row, and
  # the unique (photo_id, persona_id) index would then bar several per persona.
  # selection_state is identical for reels and stills.
  def post_in(**attrs)
    Scheduling::Post.create!(persona: persona, reel_path: 'spec.mp4', **attrs)
  end

  describe '#selection_state' do
    future_slot = 1.hour.from_now
    overdue_slot = 1.hour.ago

    states = [
      [ 'published (status posted)',            { status: 'posted' }, :published ],
      [ 'published (provider post id)',         { status: 'scheduled', provider_post_id: 'IG-1' }, :published ],
      [ 'published beats queued (both present)', { status: 'posted', scheduled_at: future_slot }, :published ],
      [ 'queued (scheduled, future slot)',      { status: 'scheduled', scheduled_at: future_slot }, :queued ],
      [ 'queued (scheduled, overdue slot)',     { status: 'scheduled', scheduled_at: overdue_slot }, :queued ],
      [ 'queued (draft, optimal time set)',     { status: 'draft', optimal_time_calculated: future_slot }, :queued ],
      [ 'queued (posting, slot)',               { status: 'posting', scheduled_at: future_slot }, :queued ],
      [ 'held (age gate, clocks cleared)',      { status: 'scheduled', caption_metadata: { 'age_gate' => { 'held' => true, 'outcome' => 'held' } } }, :held ],
      [ 'held (near-dup gate, clocks cleared)', { status: 'draft', caption_metadata: { 'near_dup_gate' => { 'held' => true, 'outcome' => 'held' } } }, :held ],
      [ 'never queued (draft, no slot)',        { status: 'draft' }, :held ],
      [ 'scheduled, both clocks cleared',       { status: 'scheduled' }, :held ],
      [ 'failed (slot retained)',               { status: 'failed', scheduled_at: future_slot }, :held ],
      [ 'awaiting an image',                    { status: 'awaiting_image' }, :held ]
    ]
    states.each do |label, attrs, expected|
      it "reads #{label} as :#{expected}" do
        expect(post_in(**attrs).selection_state).to eq(expected)
      end
    end
  end

  describe '#publicly_servable?' do
    let(:future_slot) { 1.hour.from_now }

    it 'is true exactly for :published and :queued' do
      expect(post_in(status: 'posted').publicly_servable?).to be(true)
      expect(post_in(status: 'scheduled', provider_post_id: 'IG-1').publicly_servable?).to be(true)
      expect(post_in(status: 'scheduled', scheduled_at: future_slot).publicly_servable?).to be(true)
      expect(post_in(status: 'draft', optimal_time_calculated: future_slot).publicly_servable?).to be(true)
      expect(post_in(status: 'posting', scheduled_at: future_slot).publicly_servable?).to be(true)

      expect(post_in(status: 'scheduled').publicly_servable?).to be(false)
      expect(post_in(status: 'draft').publicly_servable?).to be(false)
      expect(post_in(status: 'failed', scheduled_at: future_slot).publicly_servable?).to be(false)
      expect(post_in(status: 'awaiting_image').publicly_servable?).to be(false)
    end
  end

  describe '.publicly_servable agrees with #publicly_servable?' do
    it 'selects exactly the rows the predicate marks servable' do
      future_slot = 1.hour.from_now
      rows = [
        { status: 'posted' },
        { status: 'scheduled', provider_post_id: 'IG-1' },
        { status: 'scheduled', scheduled_at: future_slot },
        { status: 'draft', optimal_time_calculated: future_slot },
        { status: 'posting', scheduled_at: future_slot },
        { status: 'scheduled' },
        { status: 'draft' },
        { status: 'failed', scheduled_at: future_slot },
        { status: 'awaiting_image' }
      ]
      posts = rows.map { |attrs| post_in(**attrs) }

      scoped = Scheduling::Post.publicly_servable.where(id: posts.map(&:id)).pluck(:id)

      expect(scoped).to match_array(posts.select(&:publicly_servable?).map(&:id))
    end
  end
end
