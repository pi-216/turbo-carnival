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

  describe '#chat with images (vision, ticket #103)' do
    # Capture the JSON body actually sent, so the spec asserts the WIRE shape
    # the llama-server mmproj decodes, not a convenience wrapper.
    def post_capturing(response)
      bodies = []
      conn = double('conn')
      allow(Faraday).to receive(:new).and_return(conn)
      allow(conn).to receive(:post) do |_path, &blk|
        req = double('request')
        opts = double('options')
        allow(opts).to receive(:timeout=)
        allow(req).to receive(:options).and_return(opts)
        allow(req).to receive(:headers).and_return({})
        allow(req).to receive(:body=) { |b| bodies << b }
        blk.call(req)
        response
      end
      bodies
    end

    def ok_body(text)
      { 'model' => 'brain', 'choices' => [ { 'message' => { 'content' => text } } ] }.to_json
    end

    it 'attaches the image to the FIRST user message as an OpenAI-compatible image_url part' do
      bodies = post_capturing(double(success?: true, body: ok_body('ok'), status: 200))
      described_class.new.chat(
        messages: [ { role: 'user', content: 'How old does the person appear?' } ],
        images: [ 'QUJD' ]
      )

      sent = JSON.parse(bodies.last)
      expect(sent['messages'].first['content']).to eq(
        [ { 'type' => 'text', 'text' => 'How old does the person appear?' },
          { 'type' => 'image_url', 'image_url' => { 'url' => 'data:image/jpeg;base64,QUJD' } } ]
      )
    end

    it 'leaves a call with no images byte-identical to before' do
      bodies = post_capturing(double(success?: true, body: ok_body('ok'), status: 200))
      described_class.new.chat(
        messages: [ { role: 'system', content: 'sys' }, { role: 'user', content: 'hi' } ]
      )

      sent = JSON.parse(bodies.last)
      expect(sent['messages']).to eq(
        [ { 'role' => 'system', 'content' => 'sys' }, { 'role' => 'user', 'content' => 'hi' } ]
      )
    end

    it 'attaches to the first user message only, leaving later messages untouched' do
      bodies = post_capturing(double(success?: true, body: ok_body('ok'), status: 200))
      described_class.new.chat(
        messages: [
          { role: 'system', content: 'sys' },
          { role: 'user', content: 'first' },
          { role: 'user', content: 'second' }
        ],
        images: [ 'QUJD' ]
      )

      sent = JSON.parse(bodies.last)
      expect(sent['messages'][1]['content'].map { |part| part['type'] }).to eq(%w[text image_url])
      expect(sent['messages'][2]['content']).to eq('second')
    end
  end
end
