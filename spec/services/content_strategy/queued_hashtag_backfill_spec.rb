# frozen_string_literal: true

require 'rails_helper'

# The queue-side counterpart of CaptionGeneration::PlaceholderRefresh: the
# hashtag chain was repaired on 2026-09-19 on the PRODUCER side only, so a row
# already in the queue kept its empty `hashtags` and would have published
# untagged (measured: post 340, slot 09-24 17:50Z, created two minutes after the
# fix by a process still running pre-fix code). These examples pin the two
# properties that make the repair safe to run from the publisher: it never writes
# on the default dry run, and it never overwrites a row it did not repair.
RSpec.describe ContentStrategy::QueuedHashtagBackfill do
  let(:persona) { create(:persona, name: 'Sarah') }
  let!(:pillar) { create(:content_pillar, persona: persona, name: 'Travel & Adventure', weight: 20) }

  def queued_post(tags: [], at: 1.day.from_now)
    photo = ContentPillars::Photo.create!(persona: persona, content_pillar: pillar,
                                          path: "spec-#{SecureRandom.hex(4)}.png")
    Scheduling::Post.create!(persona: persona, photo: photo, caption: 'a real caption',
                             hashtags: tags, status: 'scheduled',
                             scheduled_at: at, optimal_time_calculated: at)
  end

  it 'fills an untagged queued post from the engine and leaves tagged rows alone' do
    untagged = queued_post
    tagged = queued_post(tags: [ '#kept' ])

    results = described_class.call(dry_run: false)

    expect(results.map(&:post_id)).to eq([ untagged.id ])
    # Contract, not a snapshot: the column the publisher appends is filled with
    # engine tags (up to the producers' count -- the engine returns fewer when
    # the persona has no brand_tags), including the pillar's own term.
    filled = untagged.reload.hashtags
    expect(filled).to be_present
    expect(filled.size).to be <= described_class::HASHTAG_COUNT
    expect(filled).to all(match(/\A#\S+\z/))
    expect(filled).to include('#travel')
    # The publisher appends this column verbatim; a repair that touched a
    # populated row would rewrite a post nobody asked it to change.
    expect(tagged.reload.hashtags).to eq([ '#kept' ])
  end

  it 'writes nothing on the default dry run' do
    post = queued_post

    results = described_class.call

    expect(results.map(&:outcome)).to eq([ :would_fill ])
    expect(results.first.hashtags).to be_present
    expect(post.reload.hashtags).to eq([])
  end

  it 'skips an already-due post unless include_due is set' do
    # A late tick, or a slot that passes between two ticks, is exactly when the
    # repair is needed -- the default keeps the standalone run from editing a row
    # the publisher is about to send, and INCLUDE_DUE=1 (what the publisher uses)
    # closes the hole.
    due = queued_post(at: 2.hours.ago)

    expect(described_class.call(dry_run: false)).to be_empty
    expect(due.reload.hashtags).to eq([])

    expect(described_class.call(dry_run: false, include_due: true).map(&:post_id)).to eq([ due.id ])
    expect(due.reload.hashtags).not_to be_empty
  end

  it 'reports an empty engine result instead of writing an empty column over an empty one' do
    post = queued_post
    allow(ContentStrategy::HashtagEngine).to receive(:generate).and_return([])

    results = described_class.call(dry_run: false)

    expect(results.first.outcome).to eq(:unfilled)
    expect(results.first.error).to match(/no tags/)
    expect(post.reload.hashtags).to eq([])
  end

  it 'leaves the row publishable when the engine raises' do
    post = queued_post
    allow(ContentStrategy::HashtagEngine).to receive(:generate).and_raise(NoMethodError, 'boom')

    results = described_class.call(dry_run: false)

    expect(results.first.outcome).to eq(:failed)
    expect(post.reload.hashtags).to eq([])
  end
end
