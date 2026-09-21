# frozen_string_literal: true

require 'rails_helper'

# The image path's GUARD, not its routing. Every render the growth harness
# imports is path-only (no ActiveStorage attachment), and VisionGenerator's own
# encode_image already prefers the photo's local/NAS file -- so the old guard
# (`raise unless photo.image.attached?`) refused photos this class could encode,
# and made "route path-only renders through vision" look like a change to this
# class instead of a one-line change in PostAutomation::GenerateCaption. These
# specs pin the guard to the capability it actually needs: readable bytes.
RSpec.describe CaptionGeneration::VisionGenerator do
  let(:persona) { create(:persona, :with_caption_config) }
  let(:pillar) { create(:content_pillar, persona: persona, name: 'Wellness & Self-Care') }
  let(:bytes_path) { Rails.root.join('tmp', "vision_generator_spec_#{SecureRandom.hex(4)}.png").to_s }

  # Replace AI::OllamaClient: /api/ps decides the model (ModelConfig.resolve) and
  # /api/chat answers the caption. Defined here rather than loaded from lib/ so
  # the spec never opens a socket.
  def stub_ollama_client(reply: 'A real caption', capture: nil)
    klass = Class.new do
      define_method(:initialize) { |**kwargs| capture&.call(:new, kwargs) }
      define_method(:loaded_models) { ['gemma3:4b'] }
      define_method(:chat) do |messages:, temperature:|
        capture&.call(:chat, messages)
        { text: reply, model: 'gemma3:4b' }
      end
    end
    stub_const('AI::OllamaClient', klass)
  end

  def path_only_photo(path)
    ContentPillars::Photo.create!(persona: persona, path: path, content_pillar: pillar)
  end

  before { File.binwrite(bytes_path, 'not-really-a-png-but-readable-bytes') }
  after { File.delete(bytes_path) if File.exist?(bytes_path) }

  it 'encodes a PATH-ONLY photo from its local file instead of refusing it' do
    photo = path_only_photo(bytes_path)
    expect(photo.image.attached?).to be(false)
    expect(photo.servable_file_path).to eq(bytes_path)

    sent = nil
    stub_ollama_client(reply: 'Coffee and an autumn morning.', capture: ->(what, payload) { sent = payload if what == :chat })

    result = described_class.generate(photo: photo, persona: persona, content_pillar: pillar)

    expect(result.success?).to be(true)
    expect(result.text).to eq('Coffee and an autumn morning.')
    expect(result.metadata[:generator]).to eq('vision')
    expect(sent.first[:images].first).to be_present # the bytes really were sent
  end

  it 'still uses the ActiveStorage blob when the photo has no readable local file' do
    photo = path_only_photo(Rails.root.join('tmp', 'gone.png').to_s)
    photo.image.attach(io: StringIO.new('attached-bytes'), filename: 'render.png',
                       content_type: 'image/png')
    expect(photo.servable_file_path).to be_nil

    stub_ollama_client(reply: 'From the blob.')

    result = described_class.generate(photo: photo, persona: persona, content_pillar: pillar)

    expect(result.success?).to be(true)
    expect(result.text).to eq('From the blob.')
  end

  it 'refuses a photo with no readable bytes at all, and says which guard failed' do
    photo = path_only_photo(Rails.root.join('tmp', 'never-rendered.png').to_s)

    result = described_class.generate(photo: photo, persona: persona, content_pillar: pillar)

    expect(result.success?).to be(false)
    expect(result.metadata[:error]).to include('readable image')
  end
end
