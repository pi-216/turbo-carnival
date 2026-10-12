# frozen_string_literal: true

require 'rails_helper'

# The ARM itself: the reel rail publishes due REELS posts, which is the step the
# still rail deliberately refuses to take (it excludes reel rows and only counts
# them). Without this rail a reel post is created and then never published -- the
# pivot's asset, container, serving and record steps were all built on
# 2026-09-24 and the arm still sat inert.
#
# The rule under test: a DUE reel post is published through
# GeneratePublicReelUrl -> SendReelToInstagram and records the platform id; a
# reel that is not yet due is left exactly as it was.
RSpec.describe 'scheduling:post_reels' do
  before(:all) { load_rake_tasks! }

  let(:persona) { create(:persona) }

  def reel_post(at)
    Scheduling::Post.create!(persona: persona, status: 'scheduled', reel_path: '/nonexistent/reel.mp4',
                             caption: 'a reel caption', hashtags: [ '#one' ],
                             scheduled_at: at, optimal_time_calculated: at)
  end

  def ok(returns)
    Struct.new(*returns.keys) { def success? = true; def errors = [] }
          .new(*returns.values)
  end

  it 'publishes a due reel post and records the platform id' do
    post = reel_post(1.hour.ago)

    allow(Scheduling::Commands::GeneratePublicReelUrl)
      .to receive(:call).and_return(ok({ public_reel_url: 'https://example.test/media/reels/1' }))
    allow(Scheduling::Commands::SendReelToInstagram)
      .to receive(:call!).and_return(ok({ instagram_post_id: 'ig-reel-1' }))

    Rake::Task['scheduling:post_reels'].reenable
    Rake::Task['scheduling:post_reels'].invoke

    expect(post.reload.status).to eq('posted')
    expect(post.reload.provider_post_id).to eq('ig-reel-1')
    expect(post.reload.posted_at).to be_present
  end

  it 'leaves a reel that is not yet due exactly as it was' do
    post = reel_post(2.hours.from_now)

    expect(Scheduling::Commands::SendReelToInstagram).not_to receive(:call!)

    Rake::Task['scheduling:post_reels'].reenable
    Rake::Task['scheduling:post_reels'].invoke

    expect(post.reload.status).to eq('scheduled')
    expect(post.reload.provider_post_id).to be_nil
  end

  # A failed publish must record WHY on the row, not just leave a consumed slot:
  # the same silent-failure discipline the still rail learned when a rejected
  # post stored no reason at all.
  it 'records the failure reason when the reel cannot be published' do
    post = reel_post(1.hour.ago)

    bad = Struct.new(:success?) { def errors = [ 'container rejected' ]; }
                      .new(false)
    allow(Scheduling::Commands::GeneratePublicReelUrl)
      .to receive(:call).and_return(ok({ public_reel_url: 'https://example.test/media/reels/1' }))
    allow(Scheduling::Commands::SendReelToInstagram).to receive(:call!).and_return(bad)

    Rake::Task['scheduling:post_reels'].reenable
    Rake::Task['scheduling:post_reels'].invoke

    expect(post.reload.status).to eq('failed')
    expect(post.reload.failure_reason).to include('container rejected')
  end
end
