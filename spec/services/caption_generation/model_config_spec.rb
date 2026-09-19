# frozen_string_literal: true

require 'rails_helper'

# The caption model ladder exists because gemma3:27b cannot be cold-loaded on
# max395 (16.5 GB over NFS at ~40 MB/s > Ollama's ~300s llama-server start
# timeout), so a caption call against a non-resident 27B burns the full client
# timeout and still fails - and every caller then ships the placeholder caption
# 'Fresh look'. Selection is driven by what Ollama reports as resident
# (/api/ps); these specs pin that decision table.
RSpec.describe CaptionGeneration::ModelConfig do
  ENV_KEYS = %w[CAPTION_MODEL CAPTION_FALLBACK_MODEL CAPTION_TIMEOUT
                CAPTION_FALLBACK_TIMEOUT].freeze

  around do |example|
    saved = ENV_KEYS.to_h { |k| [k, ENV[k]] }
    example.run
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  # Replace AI::OllamaClient with a stub whose /api/ps probe returns `models`
  # (or raises `error`). Defined here rather than loaded from lib/ so the spec
  # never opens a socket.
  def stub_ollama_client(models: nil, error: nil, calls: nil)
    klass = Class.new do
      define_method(:initialize) { |**_kwargs| calls&.call(:new) }
      define_method(:loaded_models) do
        calls&.call(:loaded_models)
        raise error if error

        models
      end
    end
    stub_const('AI::OllamaClient', klass)
  end

  def set_env(vars)
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  describe '.resolve' do
    it 'uses the preferred model when Ollama reports it resident' do
      stub_ollama_client(models: ['gemma3:27b'])

      expect(described_class.resolve).to eq(
        model: 'gemma3:27b', timeout: 180, reason: 'preferred_resident'
      )
    end

    it 'matches a quantised variant of the preferred tag' do
      stub_ollama_client(models: ['gemma3:27b-q4_K_M'])

      expect(described_class.resolve[:model]).to eq('gemma3:27b')
    end

    it 'falls back to a model that fits the load budget when the 27B is cold' do
      stub_ollama_client(models: ['gemma3:4b'])

      expect(described_class.resolve).to eq(
        model: 'gemma3:4b', timeout: 300, reason: 'preferred_not_resident(gemma3:27b)'
      )
    end

    it 'keeps the preferred model when the /api/ps probe fails' do
      stub_ollama_client(error: RuntimeError.new('connection refused'))

      expect(described_class.resolve).to eq(
        model: 'gemma3:27b', timeout: 180, reason: 'resident_check_unavailable'
      )
    end

    it 'does not probe at all when no fallback is configured' do
      calls = []
      stub_ollama_client(models: [], calls: ->(c) { calls << c })
      set_env('CAPTION_FALLBACK_MODEL' => '')

      expect(described_class.resolve[:reason]).to eq('no_fallback_configured')
      expect(calls).to be_empty
    end

    it 'does not probe when the fallback equals the preferred model' do
      calls = []
      stub_ollama_client(models: [], calls: ->(c) { calls << c })
      set_env('CAPTION_FALLBACK_MODEL' => 'gemma3:27b')

      expect(described_class.resolve[:reason]).to eq('no_fallback_configured')
      expect(calls).to be_empty
    end

    it 'honours env overrides for both models and both timeouts' do
      stub_ollama_client(models: [])
      set_env('CAPTION_MODEL' => 'gemma3:12b',
              'CAPTION_FALLBACK_MODEL' => 'gemma3:1b',
              'CAPTION_TIMEOUT' => '60',
              'CAPTION_FALLBACK_TIMEOUT' => '90')

      expect(described_class.resolve).to eq(
        model: 'gemma3:1b', timeout: 90, reason: 'preferred_not_resident(gemma3:12b)'
      )
    end

    it 'ignores a non-positive timeout instead of never timing out' do
      stub_ollama_client(models: ['gemma3:27b'])
      set_env('CAPTION_TIMEOUT' => '0')

      expect(described_class.resolve[:timeout]).to eq(180)
    end
  end

  describe '.loaded_models' do
    it 'is exposed by the Ollama client against /api/ps' do
      load 'lib/ai/ollama_client.rb' unless defined?(AI::OllamaClient)
      client = AI::OllamaClient.new

      response = instance_double(Faraday::Response, body: { models: [{ 'name' => 'gemma3:4b' }] }.to_json)
      connection = instance_double(Faraday::Connection, get: response)
      allow(client).to receive(:connection).and_return(connection)

      expect(client.loaded_models).to eq(['gemma3:4b'])
    end

    it 'raises a client error (not a Faraday one) when the probe fails' do
      load 'lib/ai/ollama_client.rb' unless defined?(AI::OllamaClient)
      client = AI::OllamaClient.new

      allow(client).to receive(:connection).and_raise(Faraday::ConnectionFailed.new('nope'))

      expect { client.loaded_models }.to raise_error(AI::OllamaClient::Error)
    end
  end
end
