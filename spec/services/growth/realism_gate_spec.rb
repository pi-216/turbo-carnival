# frozen_string_literal: true

require 'tmpdir'

require 'rails_helper'

# PRD 0007 B3 (ticket #110): the realism scorer is an ADVISORY MEASUREMENT -- the same
# contract Growth::NsfwGate took on in A1, and realism was the LAST veto in the render
# stack. These examples ARE the contract: they fail if a veto (a `safe` member, a
# rejection, a fail-closed error path) is ever re-introduced behind the score.
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

  # The CLI prints one JSON object per image; `decision` is derived from the same
  # thresholds, and the gate deliberately no longer reads it -- the scores are the
  # measurement, and a caller must not be able to act on a `reject`.
  def scorer_output(aesthetic_score:, sharpness: 400.0, reason: nil, error: nil)
    {
      'path' => '/tmp/x.png',
      'aesthetic_score' => aesthetic_score,
      'sharpness' => sharpness,
      'decision' => aesthetic_score.to_f >= 4.5 && sharpness.to_f >= 30.0 ? 'accept' : 'reject',
      'reason' => reason,
      'error' => error
    }
  end

  describe '#call' do
    context 'with a measured render' do
      it 'returns both scores and offers no veto for a caller to act on' do
        allow(gate).to receive(:run_scorer).and_return(scorer_output(aesthetic_score: 6.5, sharpness: 500.0))

        result = gate.call(image_path: __FILE__)

        expect(result).to be_measured
        expect(result.aesthetic_score).to eq(6.5)
        expect(result.sharpness).to eq(500.0)
        # The old contract was `safe == false -> do not queue`. Nothing on the result
        # may answer "may I publish this?" any more.
        expect(result).not_to respond_to(:safe)
      end

      it 'does not flag a render sitting exactly on both selection defaults' do
        allow(gate).to receive(:run_scorer).and_return(scorer_output(aesthetic_score: 4.5, sharpness: 30.0))

        expect(gate.call(image_path: __FILE__).flagged).to be(false)
      end

      # A below-default score is the verdict OF RECORD at the selection defaults, and
      # it is an ORDERING input (Photos::ListAvailable ranks such an asset last), not a
      # rejection: the founder's ruling keeps it for re-valuation.
      it 'flags a low aesthetic score without rejecting it' do
        allow(gate).to receive(:run_scorer).and_return(
          scorer_output(aesthetic_score: 3.2, sharpness: 400.0, reason: 'aesthetic 3.2 < 4.5')
        )

        result = gate.call(image_path: __FILE__)

        expect(result).to be_measured
        expect(result.flagged).to be(true)
        expect(result.aesthetic_score).to eq(3.2)
        expect(result.reason).to match(/aesthetic/)
      end

      it 'flags a soft render on sharpness alone' do
        allow(gate).to receive(:run_scorer).and_return(scorer_output(aesthetic_score: 6.1, sharpness: 12.4))

        expect(gate.call(image_path: __FILE__).flagged).to be(true)
      end

      it 'reads the selection defaults from the env, so the flag is overridable' do
        stub_const('ENV', ENV.to_h.merge('AESTHETIC_MODEL_DIR' => @model_dir,
                                        'AESTHETIC_THRESHOLD' => '3.0'))
        allow(gate).to receive(:run_scorer).and_return(scorer_output(aesthetic_score: 3.2, sharpness: 400.0))

        expect(gate.call(image_path: __FILE__).flagged).to be(false)
      end
    end

    # Fail-OPEN, deliberately: realism is not a floor control (PRD 0007 §1 is), so an
    # error leaves the scores UNMEASURED and the render proceeds. The old fail-closed
    # contract turned a missing model into a lost render.
    context 'when the measurement cannot be taken' do
      it 'leaves the scores unmeasured for a missing image instead of rejecting' do
        result = gate.call(image_path: '/nonexistent/render.png')

        expect(result).not_to be_measured
        expect(result.aesthetic_score).to be_nil
        expect(result.error).to match(/image missing/)
      end

      it 'leaves the scores unmeasured when the model directory is missing' do
        stub_const('ENV', 'AESTHETIC_MODEL_DIR' => '/nonexistent/model')

        result = gate.call(image_path: __FILE__) # exists, but model dir doesn't

        expect(result).not_to be_measured
        expect(result.error).to match(/model dir missing/)
      end

      it 'leaves the scores unmeasured when the scorer blows up' do
        allow(gate).to receive(:run_scorer).and_raise('boom')

        result = gate.call(image_path: __FILE__)

        expect(result).not_to be_measured
        expect(result.error).to include('boom')
      end

      # nil is "never scored"; false is "scored, and at or above the default". An
      # unmeasured render must not read as either a pass or a fail.
      it 'reports an unmeasured flag as nil, never as false' do
        expect(gate.call(image_path: '/nonexistent/render.png').flagged).to be_nil
      end
    end

    context 'when the measurement is disabled via env' do
      it 'skips the scorer and leaves the scores unmeasured' do
        stub_const('ENV', ENV.to_h.merge('AESTHETIC_GATE_DISABLED' => '1'))

        result = gate.call(image_path: '/does/not/matter.png')

        expect(result).not_to be_measured
        expect(result.error).to be_nil
      end
    end
  end
end
