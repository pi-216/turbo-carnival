# frozen_string_literal: true

require 'tmpdir'

require 'rails_helper'

# PRD 0007 A1 (ticket #104): the classifier is an ADVISORY MEASUREMENT. These
# examples ARE the contract -- they fail if a veto (a `safe` member, a rejection,
# a raise on a missing image) is ever re-introduced behind the score.
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

  # The CLI prints one JSON object per image; `decision` is derived from the same
  # threshold, and the gate deliberately no longer reads it -- the score is the
  # measurement, and a caller must not be able to act on a `reject`.
  def classifier_output(nsfw_score:, label: 'normal', error: nil)
    {
      'path' => '/tmp/x.png', 'label' => label, 'nsfw_score' => nsfw_score,
      'decision' => nsfw_score.to_f >= 0.5 ? 'reject' : 'accept', 'error' => error
    }
  end

  describe '#call' do
    context 'with a measured render' do
      it 'returns the score and offers no veto for a caller to act on' do
        allow(gate).to receive(:run_classifier)
          .and_return(classifier_output(nsfw_score: 0.9992, label: 'nsfw'))

        result = gate.call(image_path: __FILE__)

        expect(result).to be_measured
        expect(result.nsfw_score).to eq(0.9992)
        expect(result.label).to eq('nsfw')
        # The old contract was `safe == false -> do not queue`. Nothing on the
        # result may answer "may I publish this?" any more.
        expect(result).not_to respond_to(:safe)
      end

      it 'records the flag at the threshold, as the verdict of record' do
        allow(gate).to receive(:run_classifier).and_return(classifier_output(nsfw_score: 0.5))

        expect(gate.call(image_path: __FILE__).flagged).to be(true)
      end

      it 'does not flag a score below the threshold' do
        allow(gate).to receive(:run_classifier).and_return(classifier_output(nsfw_score: 0.4999))

        expect(gate.call(image_path: __FILE__).flagged).to be(false)
      end

      it 'reads the flag threshold at call time, so the stored flag is not baked in' do
        stub_const('ENV', ENV.to_h.merge('NSFW_MODEL_DIR' => @model_dir, 'NSFW_THRESHOLD' => '0.9'))
        allow(gate).to receive(:run_classifier).and_return(classifier_output(nsfw_score: 0.7))

        expect(gate.call(image_path: __FILE__).flagged).to be(false)
      end
    end

    context 'when the gate is disabled via env' do
      it 'returns an UNMEASURED result and runs no classifier' do
        stub_const('ENV', ENV.to_h.merge('NSFW_MODEL_DIR' => @model_dir, 'NSFW_GATE_DISABLED' => '1'))
        expect(gate).not_to receive(:run_classifier)

        result = gate.call(image_path: '/does/not/matter.png')

        expect(result).not_to be_measured
        expect(result.nsfw_score).to be_nil
        expect(result.flagged).to be_nil # unknown, which is not the same as false
        expect(result.error).to be_nil
      end
    end

    context 'when the image does not exist' do
      it 'reports an unmeasured score instead of rejecting' do
        result = gate.call(image_path: '/nonexistent/render.png')

        expect(result).not_to be_measured
        expect(result.error).to match(/image missing/)
      end
    end

    context 'when the model directory is missing' do
      it 'reports an unmeasured score' do
        stub_const('ENV', 'NSFW_MODEL_DIR' => '/nonexistent/model')

        result = gate.call(image_path: __FILE__) # exists, but model dir doesn't

        expect(result).not_to be_measured
        expect(result.error).to match(/model dir missing/)
      end
    end

    context 'when the classifier cannot be run' do
      it 'reports an unmeasured score rather than raising or vetoing' do
        allow(gate).to receive(:run_classifier).and_raise('boom')

        result = gate.call(image_path: __FILE__)

        expect(result).not_to be_measured
        expect(result.error).to include('boom')
      end
    end

    context 'when the classifier reports its own error' do
      it 'keeps the reason and leaves the score unmeasured' do
        allow(gate).to receive(:run_classifier)
          .and_return(classifier_output(nsfw_score: nil, error: 'load: boom'))

        result = gate.call(image_path: __FILE__)

        expect(result).not_to be_measured
        expect(result.nsfw_score).to be_nil
        expect(result.flagged).to be_nil
        expect(result.error).to eq('load: boom')
      end
    end
  end
end
