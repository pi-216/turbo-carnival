# frozen_string_literal: true

require 'tmpdir'

require 'rails_helper'

RSpec.describe Growth::NsfwGate do
  subject(:gate) { described_class.new }

  # The gate checks the model directory (default: a NAS path) exists before
  # running the classifier, so the spec must not depend on the NAS being
  # mounted: point NSFW_MODEL_DIR at an existing tmpdir. The "model directory
  # is missing" context overrides this with a nonexistent path.
  before do
    @model_dir = Dir.mktmpdir('nsfw-model')
    stub_const('ENV', ENV.to_h.merge('NSFW_MODEL_DIR' => @model_dir))
  end

  after { FileUtils.remove_entry(@model_dir) }

  describe '#call' do
    context 'when the gate is disabled via env' do
      it 'accepts without running the classifier' do
        stub_const('ENV', ENV.to_h.merge('NSFW_GATE_DISABLED' => '1'))
        result = gate.call(image_path: '/does/not/matter.png')
        expect(result.safe).to be(true)
        expect(result.error).to be_nil
      end
    end

    context 'when the image does not exist' do
      it 'rejects fail-closed with an error' do
        result = gate.call(image_path: '/nonexistent/render.png')
        expect(result.safe).to be(false)
        expect(result.error).to match(/image missing/)
      end
    end

    context 'when the model directory is missing' do
      it 'rejects fail-closed with an error' do
        stub_const('ENV', 'NSFW_MODEL_DIR' => '/nonexistent/model')
        result = gate.call(image_path: __FILE__) # exists, but model dir doesn't
        expect(result.safe).to be(false)
        expect(result.error).to match(/model dir missing/)
      end
    end

    context 'when the classifier output is malformed' do
      it 'rejects fail-closed' do
        allow(gate).to receive(:run_classifier).and_raise('boom')
        result = gate.call(image_path: __FILE__)
        expect(result.safe).to be(false)
        expect(result.error).to include('boom')
      end
    end
  end
end
