# frozen_string_literal: true

require 'rails_helper'

# The operator surface the publisher runs (bin/scheduled_posting.sh, with
# APPLY=1 INCLUDE_DUE=1). Two contracts matter: the DEFAULT is a dry run -- the
# step must never edit a live post when a human runs it by hand -- and APPLY=1
# actually fills the queue, because that is what keeps an untagged row from
# reaching Instagram.
RSpec.describe 'hashtags:backfill_queued' do
  before(:all) { load_rake_tasks! }

  let(:persona) { create(:persona, name: 'Sarah') }
  let!(:pillar) { create(:content_pillar, persona: persona, name: 'Food & Cooking', weight: 20) }

  let!(:post) do
    photo = ContentPillars::Photo.create!(persona: persona, content_pillar: pillar,
                                          path: "spec-#{SecureRandom.hex(4)}.png")
    Scheduling::Post.create!(persona: persona, photo: photo, caption: 'a real caption',
                             hashtags: [], status: 'scheduled',
                             scheduled_at: 1.day.from_now, optimal_time_calculated: 1.day.from_now)
  end

  def run_task
    Rake::Task['hashtags:backfill_queued'].reenable
    Rake::Task['hashtags:backfill_queued'].invoke
  end

  after do
    ENV.delete('APPLY')
    ENV.delete('INCLUDE_DUE')
  end

  it 'is a dry run by default' do
    run_task

    expect(post.reload.hashtags).to eq([])
  end

  it 'fills the queue when APPLY=1 is set' do
    ENV['APPLY'] = '1'

    run_task

    filled = post.reload.hashtags
    expect(filled).to be_present
    expect(filled.size).to be <= ContentStrategy::QueuedHashtagBackfill::HASHTAG_COUNT
    expect(filled).to include('#food')
    expect(filled).to all(match(/\A#\S+\z/))
  end
end
