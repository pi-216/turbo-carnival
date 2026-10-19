# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Growth::BrainGate do
  describe '.parse' do
    it 'parses an idle line (no claim, brain down)' do
      r = described_class.parse('claim=idle job=none ours=no brain=down')
      expect(r.claimed).to be(false)
      expect(r.ours).to be(false)
      expect(r.brain_up).to be(false)
      expect(r.ready?).to be(false)
      expect(r.claim_state).to eq('idle')
    end

    it 'parses our active claim with the brain up' do
      r = described_class.parse('claim=busy job=brain-123 ours=yes brain=up')
      expect(r.claimed).to be(true)
      expect(r.ours).to be(true)
      expect(r.brain_up).to be(true)
      expect(r.ready?).to be(true)
      expect(r.claim_state).to eq('ours')
    end

    it 'parses another agent holding the card' do
      r = described_class.parse('claim=busy job=bt-net-arm3 ours=no brain=down')
      expect(r.claimed).to be(true)
      expect(r.ready?).to be(false)
      expect(r.claim_state).to eq('other')
    end

    it 'returns nil for malformed output' do
      expect(described_class.parse('garbage')).to be_nil
    end
  end

  describe '.status' do
    it 'reads the harness script and parses its output' do
      allow(Open3).to receive(:capture3)
        .with(described_class::STATUS_SCRIPT.to_s, 'status')
        .and_return([ 'claim=busy job=brain-1 ours=yes brain=up', '',
                      instance_double(Process::Status, success?: true, exitstatus: 0) ])
      r = described_class.status
      expect(r.ready?).to be(true)
      expect(r.raw).to eq('claim=busy job=brain-1 ours=yes brain=up')
    end

    it 'fails closed when the script errors' do
      allow(Open3).to receive(:capture3)
        .with(described_class::STATUS_SCRIPT.to_s, 'status')
        .and_return([ '', 'no such file',
                      instance_double(Process::Status, success?: false, exitstatus: 1) ])
      r = described_class.status
      expect(r.ready?).to be(false)
      expect(r.raw).to match(/script error/)
    end

    it 'fails closed when the script raises' do
      allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT, 'nope')
      r = described_class.status
      expect(r.ready?).to be(false)
      expect(r.raw).to include('No such file')
    end
  end

  describe '.record_unclaimed!' do
    let(:goal) { create(:growth_goal) }

    it 'writes a brain_unclaimed decision row when the gate is not ready' do
      gate = described_class.parse('claim=idle job=none ours=no brain=down')
      expect do
        described_class.record_unclaimed!(goal: goal, gate: gate)
      end.to change(Growth::Decision, :count).by(1)
      expect(Growth::Decision.last.action).to eq('brain_unclaimed')
      expect(Growth::Decision.last.reason).to include('no brain claim')
    end

    it 'writes nothing when the gate is ready' do
      gate = described_class.parse('claim=busy job=brain-1 ours=yes brain=up')
      expect do
        described_class.record_unclaimed!(goal: goal, gate: gate)
      end.not_to change(Growth::Decision, :count)
    end
  end
end
