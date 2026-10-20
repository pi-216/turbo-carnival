# frozen_string_literal: true

require 'tmpdir'

require 'rails_helper'

RSpec.describe Growth::RealismGate do
  subject(:gate) { described_class.new }

  # The gate checks the model directory (default: a NAS path) exists before
  # running the scorer, so the spec must not depend on the NAS being mounted:
  # point AESTHETIC_MODEL_DIR at an existing tmpdir. The "model directory is
  # missing" context overrides this with a nonexistent path.
  before do
    @model_dir = Dir.mktmpdir('aesthetic-model')
    stub_const('ENV', ENV.to_h.merge('AESTHETIC_MODEL_DIR' => @model_dir))
  end

  after { FileUtils.remove_entry(@model_dir) }

  describe '#call' do
    context 'when the gate is disabled via env' do
      it 'accepts without running the scorer' do
        stub_const('ENV', ENV.to_h.merge('AESTHETIC_GATE_DISABLED' => '1'))
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
        stub_const('ENV', 'AESTHETIC_MODEL_DIR' => '/nonexistent/model')
        result = gate.call(image_path: __FILE__) # exists, but model dir doesn't
        expect(result.safe).to be(false)
        expect(result.error).to match(/model dir missing/)
      end
    end

    context 'when the scorer output is malformed' do
      it 'rejects fail-closed' do
        allow(gate).to receive(:run_scorer).and_raise('boom')
        result = gate.call(image_path: __FILE__)
        expect(result.safe).to be(false)
        expect(result.error).to include('boom')
      end
    end

    context 'with a low aesthetic score' do
      it 'rejects with the score in the result' do
        allow(gate).to receive(:run_scorer).and_return(
          'decision' => 'reject',
          'aesthetic_score' => 3.2,
          'sharpness' => 400.0,
          'reason' => 'aesthetic 3.2 < 4.5',
          'error' => nil
        )
        result = gate.call(image_path: __FILE__)
        expect(result.safe).to be(false)
        expect(result.aesthetic_score).to eq(3.2)
        expect(result.reason).to match(/aesthetic/)
      end
    end

    context 'with acceptable scores' do
      it 'accepts and exposes the scores' do
        allow(gate).to receive(:run_scorer).and_return(
          'decision' => 'accept',
          'aesthetic_score' => 6.5,
          'sharpness' => 500.0,
          'reason' => nil,
          'error' => nil
        )
        result = gate.call(image_path: __FILE__)
        expect(result.safe).to be(true)
        expect(result.aesthetic_score).to eq(6.5)
        expect(result.sharpness).to eq(500.0)
      end
    end
  end
end
