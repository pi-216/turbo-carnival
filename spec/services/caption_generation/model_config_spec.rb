# frozen_string_literal: true

require 'rails_helper'

# The single source of truth for the vision-read (age gate) and caption model.
#
# Ticket #103 (PRD 0007 A4 + Q1/Q2, founder ruling 2026-10-19): the brain
# REPLACES Ollama as the pipeline's serving home. The Ollama host is the same
# 4090 the brain occupies (a cold gemma3 load fails out-of-memory), and max395
# "is serving a huge model and is no longer available for serving" — so there
# is NO ladder. resolve either answers "the brain, with a ready client"
# (available: true) or "the brain is not answering" (available: false, reason
# 'brain_unavailable'); callers degrade to their floor value and record the
# reason. They never route to another host. These specs pin that contract.
RSpec.describe CaptionGeneration::ModelConfig do
  ENV_KEYS = %w[CAPTION_MODEL CAPTION_ENDPOINT CAPTION_TIMEOUT].freeze
  # The seat data as recorded in config/autonomous/brain.yml (serving.*).
  SEAT = { endpoint: 'http://127.0.0.1:8080', model: 'brain', timeout: 120 }.freeze

  around do |example|
    saved = ENV_KEYS.to_h { |k| [ k, ENV[k] ] }
    example.run
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  # Replace AI::BrainClient with a stub: /health answers `available` and
  # .config reports the seat data. Defined here rather than loaded from lib/
  # so the spec never opens a socket. Returns a log of constructor and chat
  # calls so examples can assert exactly what the client was built with.
  def stub_brain_client(available: true, config: SEAT, chat_reply: 'A caption')
    log = []
    seat = config
    klass = Class.new do
      define_singleton_method(:config) { seat }
      define_method(:initialize) do |endpoint:, model:, timeout:|
        log << [ :new, endpoint: endpoint, model: model, timeout: timeout ]
        @endpoint, @model, @timeout = endpoint, model, timeout
      end
      define_method(:available?) { available }
      define_method(:chat) do |**kwargs|
        log << [ :chat, kwargs ]
        { text: chat_reply, model: @model }
      end
    end
    stub_const('AI::BrainClient', klass)
    log
  end

  def set_env(vars)
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  describe '.config' do
    it 'is the seat data from config/autonomous/brain.yml (data, not code)' do
      expect(described_class.config).to eq(SEAT)
    end
  end

  describe '.model' do
    it 'defaults to the seat alias and is env-overridable' do
      expect(described_class.model).to eq('brain')
      set_env('CAPTION_MODEL' => 'other-alias')
      expect(described_class.model).to eq('other-alias')
    end
  end

  describe '.resolve' do
    it 'resolves to the brain with a ready client when the seat answers' do
      log = stub_brain_client(available: true)
      choice = described_class.resolve

      expect(choice[:engine]).to eq(:brain)
      expect(choice[:available]).to be(true)
      expect(choice[:reason]).to eq('brain')
      expect(choice).to include(model: 'brain', endpoint: SEAT[:endpoint], timeout: SEAT[:timeout])
      # The client was built from exactly the values the metadata records.
      expect(log).to eq([ [ :new, endpoint: SEAT[:endpoint], model: 'brain', timeout: SEAT[:timeout] ] ])
      expect(choice[:client]).to respond_to(:chat)
    end

    it 'returns brain_unavailable as a value, never a raise, when the seat is not answering' do
      stub_brain_client(available: false)
      choice = described_class.resolve

      expect(choice[:available]).to be(false)
      expect(choice[:reason]).to eq('brain_unavailable')
      # The seat values still travel with the choice, so the caller's metadata
      # can record the state the call was made against.
      expect(choice).to include(model: 'brain', endpoint: SEAT[:endpoint])
      expect(choice[:client]).to be_present
    end

    it 'logs the degradation so a dead brain cannot read as a healthy pipeline' do
      stub_brain_client(available: false)
      expect(Rails.logger).to receive(:warn).with(/brain serving home not answering/)

      described_class.resolve
    end

    it 'honours the CAPTION_MODEL / CAPTION_ENDPOINT / CAPTION_TIMEOUT overrides' do
      stub_brain_client(available: true)
      set_env('CAPTION_MODEL' => 'brain-2', 'CAPTION_ENDPOINT' => 'http://127.0.0.1:9090',
              'CAPTION_TIMEOUT' => '45')

      choice = described_class.resolve
      expect(choice).to include(model: 'brain-2', endpoint: 'http://127.0.0.1:9090', timeout: 45)
      expect(choice[:reason]).to eq('brain')
    end

    it 'falls back to the seat timeout on a non-positive CAPTION_TIMEOUT' do
      stub_brain_client(available: true)
      set_env('CAPTION_TIMEOUT' => '0')

      expect(described_class.resolve[:timeout]).to eq(SEAT[:timeout])
    end
  end

  describe '.log_failure' do
    it 'logs the endpoint, model and the error, so a degraded call is visible' do
      expect(Rails.logger).to receive(:warn).with(
        /\[caption\] vision failed endpoint=http:\/\/127\.0\.0\.1:8080 model=brain/
      )
      described_class.log_failure(component: 'vision', error: RuntimeError.new('boom'))
    end
  end
end
