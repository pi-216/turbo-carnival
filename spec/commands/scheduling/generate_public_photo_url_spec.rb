# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'
require 'zlib'

# The fail-closed publish gate (tasks 3.1/3.2/3.3 of
# openspec/changes/add-synthetic-provenance).
#
# GeneratePublicPhotoUrl is the last step of SchedulePost before
# SendPostToInstagram, and the URL it returns is a passthrough to the photo's own
# file, so checking that file here checks exactly the bytes Meta will fetch. The
# property under test is the rail's, not the marker's: an asset that cannot be
# marked must not reach Instagram::Client#create_post, and an asset that can be
# marked must publish exactly as before.
RSpec.describe Scheduling::Commands::GeneratePublicPhotoUrl do
  let(:persona) { create(:persona) }
  let(:pillar) { create(:content_pillar, persona: persona) }
  let(:client) { instance_double(Instagram::Client, create_post: { 'id' => 'ig-1' }) }

  around do |example|
    Dir.mktmpdir('gate-asset') do |dir|
      @dir = dir
      old = ENV['TURBO_CARNIVAL_PUBLIC_URL']
      ENV['TURBO_CARNIVAL_PUBLIC_URL'] = 'https://carnival.pi216.ai'
      example.run
      old.nil? ? ENV.delete('TURBO_CARNIVAL_PUBLIC_URL') : ENV['TURBO_CARNIVAL_PUBLIC_URL'] = old
    end
  end
  attr_reader :dir

  def png
    chunk = ->(type, data) { [ data.bytesize ].pack('N') + type.b + data.b + [ Zlib.crc32("#{type}#{data}") ].pack('N') }
    raw = "\x00".b + ("\xFF\x00\x00".b * 2)
    "\x89PNG\r\n\x1a\n".b +
      chunk.call('IHDR', [ 2, 1, 8, 2, 0, 0, 0 ].pack('NNC5')) +
      chunk.call('IDAT', Zlib::Deflate.deflate(raw)) +
      chunk.call('IEND', ''.b)
  end

  def photo_with(name, bytes)
    file = File.join(dir, name)
    File.binwrite(file, bytes)
    ContentPillars::Photo.create!(persona: persona, path: file, content_pillar: pillar)
  end

  describe 'the gate itself' do
    it 'marks an unmarked asset in flight and returns the tunnel URL' do
      photo = photo_with('fresh.png', png)

      result = described_class.call(photo: photo)

      expect(result).to be_success
      expect(result.public_photo_url).to eq("https://carnival.pi216.ai/media/photos/#{photo.id}")
      expect(ContentPillars::PhotoAssetMarker.marked?(photo.path)).to be(true)
      expect(photo.reload.provenance['embedded']).to be(true)
    end

    it 'publishes an already-marked photo without rewriting its bytes' do
      photo = photo_with('marked.png', png)
      photo.mark_synthetic_asset!
      before = File.binread(photo.path)

      result = described_class.call(photo: photo)

      expect(result).to be_success
      expect(File.binread(photo.path)).to eq(before)
    end

    it 'blocks, with the remedy named, when the asset cannot be marked' do
      photo = photo_with('weird.png', 'GIF89a-not-a-png')

      result = described_class.call(photo: photo)

      expect(result).not_to be_success
      expect(result.full_error_message).to include('no machine-readable synthetic mark')
      expect(result.full_error_message).to include("PHOTO_ID=#{photo.id}")
      expect(result.public_photo_url).to be_nil
    end
  end

  describe 'the rail: an unmarked asset never reaches Instagram' do
    before { allow(Instagram::Client).to receive(:new).and_return(client) }

    it 'does not construct the Instagram client when the photo cannot be marked' do
      photo = photo_with('weird.png', 'GIF89a-not-a-png')
      expect(Instagram::Client).not_to receive(:new)

      result = Scheduling::SchedulePost.call(photo: photo, persona: persona, caption: 'a caption')

      expect(result).not_to be_success
      expect(Scheduling::Post.count).to eq(0)
    end

    it 'publishes normally once the asset carries the mark' do
      photo = photo_with('fresh.png', png)

      result = Scheduling::SchedulePost.call(photo: photo, persona: persona, caption: 'a caption')

      expect(result).to be_success
      expect(client).to have_received(:create_post)
        .with(image_url: "https://carnival.pi216.ai/media/photos/#{photo.id}", caption: 'a caption')
      expect(Scheduling::Post.last.provider_post_id).to eq('ig-1')
      expect(photo.reload.provenance['embedded']).to be(true)
    end
  end
end
