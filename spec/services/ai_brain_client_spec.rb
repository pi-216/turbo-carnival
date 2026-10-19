# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib', 'ai', 'brain_client')

RSpec.describe AI::BrainClient do
  describe '.config' do
    it 'reads endpoint and alias from config/autonomous/brain.yml (data, not code)' do
      described_class.instance_variable_set(:@config, nil)
      cfg = described_class.config
      expect(cfg[:endpoint]).to eq('http://127.0.0.1:8080')
      expect(cfg[:model]).to eq('brain')
    end
  end

  describe '#available?' do
    it 'is true when /health answers' do
      conn = double('conn')
      allow(Faraday).to receive(:new).and_return(conn)
      allow(conn).to receive(:get).and_return(double(success?: true))
      expect(described_class.new.available?).to be(true)
    end

    it 'is false (fail-closed) when the connection is refused' do
      allow(Faraday).to receive(:new).and_raise(Faraday::ConnectionFailed.new('refused'))
      expect(described_class.new.available?).to be(false)
    end
  end

  describe '#generate' do
    def stub_post(response)
      conn = double('conn')
      allow(Faraday).to receive(:new).and_return(conn)
      allow(conn).to receive(:post).and_return(response)
    end

    it 'returns the assistant content, never the reasoning_content' do
      body = {
        'model' => 'brain',
        'choices' => [ { 'message' => { 'content' => ' a usable brief ', 'reasoning_content' => 'hidden chain' } } ]
      }.to_json
      stub_post(double(success?: true, body: body, status: 200))
      expect(described_class.new.generate('hi', system: 'sys')).to eq('a usable brief')
    end

    it 'raises on a non-success response' do
      stub_post(double(success?: false, body: '{"error":"boom"}', status: 500))
      expect { described_class.new.generate('hi') }.to raise_error(AI::BrainClient::Error, /boom/)
    end

    it 'raises when the model returns no content' do
      body = { 'choices' => [ { 'message' => { 'content' => '' } } ] }.to_json
      stub_post(double(success?: true, body: body, status: 200))
      expect { described_class.new.generate('hi') }.to raise_error(AI::BrainClient::Error, /empty/)
    end
  end
end
