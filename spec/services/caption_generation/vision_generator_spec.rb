# frozen_string_literal: true

require 'rails_helper'

# The image path's GUARD and its serving home. Every render the growth harness
# imports is path-only (no ActiveStorage attachment), and VisionGenerator's own
# encode_image already prefers the photo's local/NAS file -- so the guard
# accepts anything with readable bytes, not just attached photos. Since ticket
# #103 the model is the brain (ModelConfig.resolve): the image and the prompt
# ride ONE OpenAI-compatible chat call, and a brain that is not answering is a
# recorded failure (model_selection 'brain_unavailable'), not a timeout on a
# dead host. These specs pin the guard and the new failure shape.
RSpec.describe CaptionGeneration::VisionGenerator do
  let(:persona) { create(:persona, :with_caption_config) }
  let(:pillar) { create(:content_pillar, persona: persona, name: 'Wellness & Self-Care') }
  let(:bytes_path) { Rails.root.join('tmp', "vision_generator_spec_#{SecureRandom.hex(4)}.png").to_s }

  # The seat data as recorded in config/autonomous/brain.yml (serving.*).
  SEAT = { endpoint: 'http://127.0.0.1:8080', model: 'brain', timeout: 120 }.freeze

  # Replace AI::BrainClient with a stub: /health answers `available`, chat
  # replies (or raises `error`). Defined here rather than loaded from lib/ so
  # the spec never opens a socket. Returns a log of constructor and chat calls.
  def stub_brain_client(available: true, reply: 'A real caption', error: nil)
    log = []
    seat = SEAT
    klass = Class.new do
      define_singleton_method(:config) { seat }
      define_method(:initialize) { |**kwargs| log << [ :new, kwargs ] }
      define_method(:available?) { available }
      define_method(:chat) do |**kwargs|
        log << [ :chat, kwargs ]
        raise error if error

        { text: reply, model: 'brain' }
      end
    end
    stub_const('AI::BrainClient', klass)
    log
  end

  def path_only_photo(path)
    ContentPillars::Photo.create!(persona: persona, path: path, content_pillar: pillar)
  end

  before { File.binwrite(bytes_path, 'not-really-a-png-but-readable-bytes') }
  after { File.delete(bytes_path) if File.exist?(bytes_path) }

  it 'encodes a PATH-ONLY photo from its local file and sends it on the brain chat call' do
    photo = path_only_photo(bytes_path)
    expect(photo.image.attached?).to be(false)
    expect(photo.servable_file_path).to eq(bytes_path)

    log = stub_brain_client(reply: 'Coffee and an autumn morning.')

    result = described_class.generate(photo: photo, persona: persona, content_pillar: pillar)

    expect(result.success?).to be(true)
    expect(result.text).to eq('Coffee and an autumn morning.')
    expect(result.metadata[:generator]).to eq('vision')
    expect(result.metadata[:model]).to eq('brain')
    expect(result.metadata[:model_selection]).to eq('brain')
    sent = log.find { |entry| entry[0] == :chat }
    expect(sent).to be_present                          # the model really was called
    expect(sent[1][:images].first).to be_present        # ... with the photo's bytes
    expect(sent[1][:messages].first[:content]).to be_a(String) # prompt text, not parts
  end

  it 'still uses the ActiveStorage blob when the photo has no readable local file' do
    photo = path_only_photo(Rails.root.join('tmp', 'gone.png').to_s)
    photo.image.attach(io: StringIO.new('attached-bytes'), filename: 'render.png',
                       content_type: 'image/png')
    expect(photo.servable_file_path).to be_nil

    stub_brain_client(reply: 'From the blob.')

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

  it 'is a recorded failure with reason brain_unavailable when the seat is not answering' do
    photo = path_only_photo(bytes_path)
    stub_brain_client(available: false)

    result = described_class.generate(photo: photo, persona: persona, content_pillar: pillar)

    expect(result.success?).to be(false)
    expect(result.text).to eq('')
    expect(result.metadata[:model_selection]).to eq('brain_unavailable')
    expect(result.metadata[:error]).to include('not answering')
  end

  it 'is a recorded failure when the brain call itself fails, keeping the selection reason' do
    photo = path_only_photo(bytes_path)
    stub_brain_client(error: RuntimeError.new('seat exploded'))

    result = described_class.generate(photo: photo, persona: persona, content_pillar: pillar)

    expect(result.success?).to be(false)
    expect(result.metadata[:model_selection]).to eq('brain')
    expect(result.metadata[:error]).to include('seat exploded')
  end
end
