# frozen_string_literal: true

require 'rails_helper'

# The SAFETY read: a question about a photo answered by the vision model as
# raw text (the age gate's read), with no caption post-processing. Since
# ticket #103 it resolves to the brain (ModelConfig.resolve) and rides the
# same OpenAI-compatible chat call as the caption path.
#
# The contract this class exists to hold: failures are VALUES, never
# exceptions. A gate must be able to say "I could not read this" and let
# publishing continue unchanged (fail-open) -- including when the serving home
# itself is down. That case returns unreadable with the REASON recorded, so
# the gate's warning names the outage instead of a network error string, and
# nothing was ever sent to a dead seat.
RSpec.describe CaptionGeneration::VisionProbe do
  let(:persona) { create(:persona) }
  let(:pillar) { create(:content_pillar, persona: persona) }
  let(:bytes_path) { Rails.root.join('tmp', "vision_probe_spec_#{SecureRandom.hex(4)}.png").to_s }

  # The seat data as recorded in config/autonomous/brain.yml (serving.*).
  SEAT = { endpoint: 'http://127.0.0.1:8080', model: 'brain', timeout: 120 }.freeze

  # Replace AI::BrainClient with a stub: /health answers `available`, chat
  # replies (or raises `error`). Defined here rather than loaded from lib/ so
  # the spec never opens a socket. Returns a log of constructor and chat calls.
  def stub_brain_client(available: true, reply: 'AGE: adult', error: nil)
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

  it 'returns the raw read with the selection reason when the brain answers' do
    photo = path_only_photo(bytes_path)
    stub_brain_client(reply: "AGE: adult\nCUES: face and build read as mid-twenties.")

    result = described_class.ask(photo: photo, question: 'How old does the person appear?')

    expect(result.ok?).to be(true)
    expect(result.text).to start_with('AGE: adult')
    expect(result.model).to eq('brain')
    expect(result.model_selection).to eq('brain')
    expect(result.error).to be_nil
  end

  it 'sends the photo on the same chat call as the question' do
    photo = path_only_photo(bytes_path)
    log = stub_brain_client

    described_class.ask(photo: photo, question: 'How old does the person appear?')

    sent = log.find { |entry| entry[0] == :chat }
    expect(sent).to be_present
    expect(sent[1][:messages].first[:content]).to eq('How old does the person appear?')
    expect(sent[1][:images].first).to be_present
    expect(sent[1][:temperature]).to eq(CaptionGeneration::VisionProbe::DEFAULT_TEMPERATURE)
  end

  it 'is unreadable BY VALUE when the brain is not answering, with the reason recorded' do
    photo = path_only_photo(bytes_path)
    log = stub_brain_client(available: false)

    result = described_class.ask(photo: photo, question: 'How old does the person appear?')

    expect(result.ok?).to be(false)
    expect(result.text).to eq('')
    expect(result.error).to eq('brain_unavailable')
    expect(result.model_selection).to eq('brain_unavailable')
    expect(log.select { |entry| entry[0] == :chat }).to be_empty # nothing was sent
  end

  it 'is unreadable when the brain call itself fails' do
    photo = path_only_photo(bytes_path)
    stub_brain_client(error: RuntimeError.new('connection reset'))

    result = described_class.ask(photo: photo, question: 'How old does the person appear?')

    expect(result.ok?).to be(false)
    expect(result.error).to include('connection reset')
  end

  it 'is unreadable BY VALUE for a photo with no readable bytes, without touching the seat' do
    photo = path_only_photo(Rails.root.join('tmp', 'never-rendered.png').to_s)
    log = stub_brain_client

    result = described_class.ask(photo: photo, question: 'How old does the person appear?')

    # The guard fires before any seat traffic: the failure is a value whose
    # error names the guard, and nothing was ever sent to the model.
    expect(result.ok?).to be(false)
    expect(result.text).to eq('')
    expect(result.error).to include('readable image')
    expect(log.select { |entry| entry[0] == :chat }).to be_empty
  end

  describe '.Result' do
    it 'is ok only with text and no error' do
      ok = CaptionGeneration::VisionProbe::Result.new(text: 'read', model: 'brain',
                                                      model_selection: 'brain')
      expect(ok.ok?).to be(true)
      expect(CaptionGeneration::VisionProbe::Result.new(text: '', error: 'boom').ok?).to be(false)
      expect(CaptionGeneration::VisionProbe::Result.new(text: '  ', error: nil).ok?).to be(false)
    end
  end
end
