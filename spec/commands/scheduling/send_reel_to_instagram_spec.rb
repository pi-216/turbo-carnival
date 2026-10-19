# frozen_string_literal: true

require 'rails_helper'

# The arm's PUBLISH step. Instagram::Client#create_reel was built 2026-09-24 and
# verified against the live tunnel, but until this command existed nothing in
# production called it -- so the pre-registered discovery pivot was declared and
# inert (bin/tc_ops.py check_reel_arm_stall keys on exactly this call). These
# examples pin the two things the rail depends on: the reel's asset URL and
# caption reach create_reel unchanged, and a client failure surfaces as a failed
# command rather than a silently unpublishable reel.
RSpec.describe Scheduling::Commands::SendReelToInstagram do
  let(:client) { instance_double(Instagram::Client) }
  # Stubbed rather than constructed: Instagram::Client#initialize raises without
  # credentials, and this example is about what the command SENDS.
  before { allow(Instagram::Client).to receive(:new).and_return(client) }

  def call(**opts)
    described_class.call(public_reel_url: 'https://carnival.pi216.ai/media/reels/7',
                         caption: 'a caption', persona: 'Sarah', **opts)
  end

  it 'publishes the reel URL and caption through create_reel and returns the id' do
    expect(client).to receive(:create_reel)
      .with(video_url: 'https://carnival.pi216.ai/media/reels/7', caption: 'a caption')
      .and_return({ 'id' => 'ig-reel-9' })

    result = call

    expect(result).to be_success
    expect(result.instagram_post_id).to eq('ig-reel-9')
  end

  it 'surfaces a client error as a failed command instead of a released slot' do
    allow(client).to receive(:create_reel).and_raise(Instagram::Client::Error, 'container rejected')

    result = call

    expect(result).not_to be_success
    expect(result.errors.full_messages.join(' ')).to include('container rejected')
  end

  it 'fails when the platform returns no reel id' do
    allow(client).to receive(:create_reel).and_return({})

    result = call

    expect(result).not_to be_success
    expect(result.errors.full_messages.join(' ')).to include('did not return a reel ID')
  end
end
