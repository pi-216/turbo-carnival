# frozen_string_literal: true

require 'rails_helper'

# The TEXT caption path: taken when the photo has no readable bytes (renders
# imported by the growth harness are path-only and readable, so this is the
# fallback, not the norm). Since ticket #103 it resolves to the brain exactly
# like the vision path, and a brain that is not answering is a recorded
# failure -- the placeholder ships with model_selection 'brain_unavailable' --
# never a raise to the caller and never a hang on a dead host.
RSpec.describe CaptionGeneration::Generator do
  let(:persona) { create(:persona, :with_caption_config) }
  let(:pillar) { create(:content_pillar, persona: persona, name: 'Fashion & Style') }

  # The seat data as recorded in config/autonomous/brain.yml (serving.*).
  SEAT = { endpoint: 'http://127.0.0.1:8080', model: 'brain', timeout: 120 }.freeze

  def stub_brain_client(available: true, reply: 'A caption about the photo.')
    seat = SEAT
    klass = Class.new do
      define_singleton_method(:config) { seat }
      define_method(:initialize) { |**kwargs| }
      define_method(:available?) { available }
      define_method(:chat) { |**_kwargs| { text: reply, model: 'brain' } }
    end
    stub_const('AI::BrainClient', klass)
  end

  def photo
    ContentPillars::Photo.create!(persona: persona, path: '/tmp/gen_spec_missing.png',
                                  content_pillar: pillar)
  end

  it 'records the brain selection when the seat answers' do
    stub_brain_client

    result = described_class.generate(photo: photo, persona: persona)

    expect(result.success?).to be(true)
    expect(result.metadata[:model]).to eq('brain')
    expect(result.metadata[:model_selection]).to eq('brain')
    expect(result.metadata[:generator]).to eq('text')
  end

  it 'is a recorded failure with reason brain_unavailable when the seat is not answering' do
    stub_brain_client(available: false)

    result = described_class.generate(photo: photo, persona: persona)

    expect(result.success?).to be(false)
    expect(result.text).to eq('')
    expect(result.metadata[:model_selection]).to eq('brain_unavailable')
    expect(result.metadata[:error]).to eq('brain_unavailable')
  end
end
