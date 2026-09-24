# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'

# The REELS publish rail's URL step, twin of GeneratePublicPhotoUrl.
#
# Why this spec exists (ops decision 2026-09-24): the pre-registered pivot to a
# discovery surface (Reels) had a client (`Instagram::Client#create_reel`) that
# takes a `video_url:` and NOTHING that could produce one -- MediaController
# served `image/png` for a Photo and no video endpoint existed. These examples
# pin the finished rail: a marked reel on disk resolves to the tunnel URL, and an
# asset that cannot testify to being synthetic does NOT reach the client.
RSpec.describe Scheduling::Commands::GeneratePublicReelUrl do
  let(:persona) { create(:persona) }
  let(:pillar) { create(:content_pillar, persona: persona) }

  around do |example|
    Dir.mktmpdir('reel-url') do |dir|
      @dir = dir
      old = ENV['TURBO_CARNIVAL_PUBLIC_URL']
      ENV['TURBO_CARNIVAL_PUBLIC_URL'] = 'https://carnival.pi216.ai'
      example.run
      old.nil? ? ENV.delete('TURBO_CARNIVAL_PUBLIC_URL') : ENV['TURBO_CARNIVAL_PUBLIC_URL'] = old
    end
  end
  attr_reader :dir

  # An MP4 whose container carries the IPTC mark, byte-for-byte what
  # Growth::ReelBuilder writes (-metadata Iptc4xmpExt:DigitalSourceType=...).
  def marked_mp4(name = 'reel.mp4')
    file = File.join(dir, name)
    File.binwrite(file, "ftypisom....moov....udta....Iptc4xmpExt:DigitalSourceType=" \
                        'http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia')
    file
  end

  def unmarked_mp4(name = 'reel.mp4')
    file = File.join(dir, name)
    File.binwrite(file, 'ftypisom....moov....no marker here')
    file
  end

  def reel_post(path)
    Scheduling::Post.create!(persona: persona, status: 'scheduled', reel_path: path)
  end

  # A STILL post: a photo, no reel_path. Same shape every existing row has.
  def still_post
    photo = ContentPillars::Photo.create!(persona: persona, content_pillar: pillar,
                                          path: File.join(dir, 'still.png'))
    Scheduling::Post.create!(persona: persona, photo: photo, status: 'scheduled')
  end

  describe 'the rail' do
    it 'resolves a marked reel to the tunnel URL Instagram will fetch' do
      post = reel_post(marked_mp4)

      result = described_class.call(post: post)

      expect(result).to be_success
      expect(result.public_reel_url).to eq("https://carnival.pi216.ai/media/reels/#{post.id}")
    end

    it 'refuses a reel with no machine-readable mark (the synthetic-media red line)' do
      post = reel_post(unmarked_mp4)

      result = described_class.call(post: post)

      expect(result).to be_failure
      expect(result.public_reel_url).to be_nil
      expect(result.errors.full_messages.join(' ')).to include('no machine-readable synthetic mark')
    end

    it 'refuses a still post -- there is no video to publish' do
      post = still_post

      result = described_class.call(post: post)

      expect(result).to be_failure
      expect(result.errors.full_messages.join(' ')).to include('not a REELS post')
    end

    it 'refuses a reel whose file is gone, naming the rebuild' do
      post = reel_post(File.join(dir, 'deleted.mp4'))

      result = described_class.call(post: post)

      expect(result).to be_failure
      expect(result.errors.full_messages.join(' ')).to include('missing on disk')
    end

    it 'refuses when no public base URL is configured (Instagram could not fetch it)' do
      post = reel_post(marked_mp4)
      ENV.delete('TURBO_CARNIVAL_PUBLIC_URL')
      allow(Rails.application.credentials).to receive(:dig).and_return(nil)

      result = described_class.call(post: post)

      expect(result).to be_failure
      expect(result.errors.full_messages.join(' ')).to include('No public base URL')
    end
  end

  describe 'the post discriminator' do
    it 'reads a post with no reel_path as a still, unchanged' do
      expect(still_post.reel?).to be(false)
      expect(reel_post(marked_mp4).reel?).to be(true)
    end

    it 'can be scheduled with no photo -- a reel is not one render' do
      post = Scheduling::Post.create!(persona: persona, status: 'scheduled', reel_path: marked_mp4)

      expect(post).to be_persisted
      expect(post.reel?).to be(true)
      expect(post.photo_id).to be_nil
    end

    it 'still refuses a photo-less STILL post ready to publish' do
      expect do
        Scheduling::Post.create!(persona: persona, status: 'scheduled')
      end.to raise_error(ActiveRecord::RecordInvalid, /Photo can't be blank/)
    end
  end
end