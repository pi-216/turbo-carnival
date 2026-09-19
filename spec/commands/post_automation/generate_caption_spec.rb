# frozen_string_literal: true

require 'rails_helper'

# The branch that decides whether a caption ever LOOKS at the render. No photo
# created by the growth harness since 2026-05-28 has an ActiveStorage attachment
# (import_photo is path-only), so in production this command always takes the
# text path and CaptionGeneration::VisionGenerator is unreachable. Pinned here so
# that flipping it is a deliberate, tested change rather than an accident.
RSpec.describe PostAutomation::GenerateCaption do
  let(:persona) { create(:persona, :with_caption_config) }
  let(:pillar) { create(:content_pillar, persona: persona, name: 'Fashion & Style') }
  let!(:photo) do
    ContentPillars::Photo.create!(persona: persona, path: '/tmp/gen_caption_spec.png',
                                  content_pillar: pillar)
  end

  let(:ok_result) do
    CaptionGeneration::Result.new(text: 'A caption', success: true,
                                  metadata: { model: 'gemma3:4b', model_selection: 'preferred_resident' })
  end

  it 'takes the vision path when the photo carries an attached image' do
    photo.image.attach(io: StringIO.new('bytes'), filename: 'render.png', content_type: 'image/png')

    expect(CaptionGeneration::VisionGenerator).to receive(:generate).and_return(ok_result)

    result = described_class.call(photo: photo, persona: persona, pillar: pillar)

    expect(result).to be_success
    expect(result.caption).to eq('A caption')
    expect(result.caption_metadata[:model]).to eq('gemma3:4b')
  end

  it 'takes the text path for a path-only photo (how the growth harness imports renders)' do
    expect(CaptionGeneration::Generator).to receive(:generate).and_return(ok_result)

    result = described_class.call(photo: photo, persona: persona, pillar: pillar)

    expect(result).to be_success
    expect(result.caption).to eq('A caption')
  end

  it 'fails the command so the caller ships the placeholder, keeping the reason' do
    failed = CaptionGeneration::Result.new(text: '', success: false,
                                           metadata: { error: 'timed out', model: 'gemma3:27b' })
    allow(CaptionGeneration::Generator).to receive(:generate).and_return(failed)

    result = described_class.call(photo: photo, persona: persona, pillar: pillar)

    expect(result).not_to be_success
    expect(result.full_error_message).to include('timed out')
  end
end
