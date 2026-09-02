# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Growth::SchedulerGate do
  describe '.parse' do
    it 'parses an idle claim line' do
      r = described_class.parse('claim=idle job=none ours=no comfyui=down')
      expect(r.claimed).to be(false)
      expect(r.ours).to be(false)
      expect(r.comfyui_up).to be(false)
      expect(r.ready?).to be(false)
      expect(r.claim_state).to eq('idle')
    end

    it 'parses an active claim of ours with ComfyUI up' do
      r = described_class.parse('claim=busy job=comfyui-123 ours=yes comfyui=up')
      expect(r.claimed).to be(true)
      expect(r.ours).to be(true)
      expect(r.comfyui_up).to be(true)
      expect(r.ready?).to be(true)
      expect(r.claim_state).to eq('ours')
    end

    it 'parses another agent holding the GPU' do
      r = described_class.parse('claim=busy job=bt-net-arm3 ours=no comfyui=down')
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
        .and_return(['claim=busy job=comfyui-1 ours=yes comfyui=up', '', instance_double(Process::Status, success?: true, exitstatus: 0)])
      r = described_class.status
      expect(r.ready?).to be(true)
      expect(r.raw).to eq('claim=busy job=comfyui-1 ours=yes comfyui=up')
    end

    it 'fails closed when the script errors' do
      allow(Open3).to receive(:capture3)
        .with(described_class::STATUS_SCRIPT.to_s, 'status')
        .and_return(['', 'no such file', instance_double(Process::Status, success?: false, exitstatus: 1)])
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
end