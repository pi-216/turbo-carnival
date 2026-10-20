# frozen_string_literal: true

require 'rails_helper'

# The branch that decides whether a caption ever LOOKS at the render.
#
# History: no photo created by the growth harness since 2026-05-28 has an
# ActiveStorage attachment (import_photo is path-only), so branching on
# `image.attached?` sent every production caption down the TEXT path and made
# CaptionGeneration::VisionGenerator unreachable -- the caption was invented from
# the photo's context text. The branch now routes on READABLE BYTES, which is
# what the vision class actually needs, so a path-only render with a resolvable
# file takes the image path. These examples pin both directions, including the
# one case that must still fall back to text: a photo with no bytes at all.
RSpec.describe PostAutomation::GenerateCaption do
  let(:persona) { create(:persona, :with_caption_config) }
  let(:pillar) { create(:content_pillar, persona: persona, name: 'Fashion & Style') }
  let(:bytes_path) { Rails.root.join('tmp', "generate_caption_spec_#{SecureRandom.hex(4)}.png").to_s }
  let!(:photo) do
    ContentPillars::Photo.create!(persona: persona, path: '/tmp/gen_caption_spec_missing.png',
                                  content_pillar: pillar)
  end

  let(:ok_result) do
    CaptionGeneration::Result.new(text: 'A caption', success: true,
                                  metadata: { model: 'brain', model_selection: 'brain' })
  end

  after { File.delete(bytes_path) if File.exist?(bytes_path) }

  it 'takes the vision path when the photo carries an attached image' do
    photo.image.attach(io: StringIO.new('bytes'), filename: 'render.png', content_type: 'image/png')

    expect(CaptionGeneration::VisionGenerator).to receive(:generate).and_return(ok_result)

    result = described_class.call(photo: photo, persona: persona, pillar: pillar)

    expect(result).to be_success
    expect(result.caption).to eq('A caption')
    expect(result.caption_metadata[:model]).to eq('brain')
  end

  it 'takes the vision path for a PATH-ONLY render that has a readable file' do
    File.binwrite(bytes_path, 'not-really-a-png-but-readable-bytes')
    photo.update!(path: bytes_path)

    expect(photo.image.attached?).to be(false)
    expect(CaptionGeneration::VisionGenerator).to receive(:generate).and_return(ok_result)
    expect(CaptionGeneration::Generator).not_to receive(:generate)

    result = described_class.call(photo: photo, persona: persona, pillar: pillar)

    expect(result).to be_success
    expect(result.caption).to eq('A caption')
  end

  it 'falls back to the text path when the photo has no readable bytes at all' do
    expect(photo.image.attached?).to be(false)
    expect(photo.servable_file_path).to be_nil
    expect(CaptionGeneration::Generator).to receive(:generate).and_return(ok_result)
    expect(CaptionGeneration::VisionGenerator).not_to receive(:generate)

    result = described_class.call(photo: photo, persona: persona, pillar: pillar)

    expect(result).to be_success
    expect(result.caption).to eq('A caption')
  end

  it 'fails the command so the caller ships the placeholder, keeping the reason' do
    failed = CaptionGeneration::Result.new(text: '', success: false,
                                           metadata: { error: 'timed out', model: 'brain' })
    allow(CaptionGeneration::Generator).to receive(:generate).and_return(failed)

    result = described_class.call(photo: photo, persona: persona, pillar: pillar)

    expect(result).not_to be_success
    expect(result.full_error_message).to include('timed out')
  end
end
