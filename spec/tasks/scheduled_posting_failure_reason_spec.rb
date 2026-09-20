# frozen_string_literal: true

require 'rails_helper'

# A rejected post must leave a REASON behind on the row.
#
# Root cause this pins: the publisher called mark_as_failed! with no argument, so
# the only record of WHY a slot was lost (Instagram 400 code 9007 "media not
# ready for publishing") was a line in log/scheduled_posting.log -- which rotates
# away and which no DB-side check reads. bin/tc_ops.py's silent-failure detector
# could then report a lost slot but never the cause, and the (deliberately
# human-owned) retry decision had no data behind it.
#
# Asserted through the REAL task, not the model, because the regression was in
# the caller: a model method nobody invokes fixes nothing.
RSpec.describe 'scheduling:post_scheduled failure reason' do
  before(:all) { load_rake_tasks! }

  let(:persona) { create(:persona) }
  let(:pillar) { create(:content_pillar, persona: persona) }

  def due_post
    photo = ContentPillars::Photo.create!(persona: persona, path: "spec-#{SecureRandom.hex(4)}.png",
                                          content_pillar: pillar)
    Scheduling::Post.create!(persona: persona, photo: photo, caption: 'a real caption',
                             status: 'scheduled', scheduled_at: 1.hour.ago,
                             optimal_time_calculated: 1.hour.ago)
  end

  # Same shape the commands return: #success?, #errors plus the payload keys.
  def command_result(success, returns)
    Struct.new(*returns.keys) { define_method(:success?) { success } }.new(*returns.values)
  end

  def run_publisher!
    Rake::Task['scheduling:post_scheduled'].reenable
    Rake::Task['scheduling:post_scheduled'].invoke
  end

  it 'stores the Instagram error on the failed row' do
    post = due_post

    allow(Scheduling::Commands::GeneratePublicPhotoUrl)
      .to receive(:call!).and_return(command_result(true, { public_photo_url: 'https://example.test/p.png' }))
    allow(Scheduling::Commands::SendPostToInstagram)
      .to receive(:call!).and_return(
        command_result(false,
                       { instagram_post_id: nil,
                         errors: [ '400 code 9007: Media ID is not available -- the media is not ready for publishing' ] })
      )

    run_publisher!

    post.reload
    expect(post.status).to eq('failed')
    expect(post.failure_reason).to start_with('instagram:')
    expect(post.failure_reason).to include('9007')
  end

  it 'stores a bounded reason for a URL-generation failure' do
    post = due_post

    allow(Scheduling::Commands::GeneratePublicPhotoUrl)
      .to receive(:call!).and_return(command_result(false, { public_photo_url: nil, errors: [ 'tunnel 502' ] }))

    run_publisher!

    post.reload
    expect(post.status).to eq('failed')
    expect(post.failure_reason).to eq('url_generation: tunnel 502')
  end
end
