# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Growth::PhaseHandoff do
  describe '.parse' do
    it 'parses an admitted render phase' do
      r = described_class.parse('phase=render outgoing=brain tenant=down free=20000MiB floor=16GiB verdict=proceed')
      expect(r.ready?).to be(true)
      expect(r.phase).to eq('render')
      expect(r.free_mib).to eq(20_000)
      expect(r.floor_gib).to eq(16)
      expect(r.tenant_state).to eq('down')
    end

    it 'parses a vram-insufficient park' do
      r = described_class.parse('phase=render outgoing=brain tenant=down free=10000MiB floor=16GiB verdict=park:vram_insufficient')
      expect(r.ready?).to be(false)
      expect(r.park_reason).to eq('vram_insufficient')
      expect(r.free_mib).to eq(10_000)
    end

    it 'parses a tenant-resident park' do
      r = described_class.parse('phase=render outgoing=brain tenant=up free=99999MiB floor=16GiB verdict=park:tenant_resident')
      expect(r.ready?).to be(false)
      expect(r.park_reason).to eq('tenant_resident')
    end

    it 'parses an unreadable device without inventing a number' do
      r = described_class.parse('phase=render outgoing=brain tenant=down free=unreadable floor=16GiB verdict=park:vram_unreadable')
      expect(r.ready?).to be(false)
      expect(r.free_mib).to be_nil
    end

    it 'returns nil for malformed output' do
      expect(described_class.parse('garbage')).to be_nil
    end
  end

  describe '.check' do
    it 'reads the harness even when it exits non-zero on a park' do
      allow(Open3).to receive(:capture3)
        .with(described_class::STATUS_SCRIPT.to_s, 'check', 'render')
        .and_return([ 'phase=render outgoing=brain tenant=up free=30000MiB floor=16GiB verdict=park:tenant_resident',
                      '', instance_double(Process::Status, success?: false, exitstatus: 3) ])
      r = described_class.check(phase: :render)
      expect(r.ready?).to be(false)
      expect(r.park_reason).to eq('tenant_resident')
    end

    it 'fails closed when the harness cannot be read' do
      allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT, 'nope')
      r = described_class.check
      expect(r.ready?).to be(false)
      expect(r.park_reason).to eq('vram_unreadable')
      expect(r.raw).to include('No such file')
    end
  end

  describe '.record_insufficient!' do
    let(:goal) { create(:growth_goal) }

    it 'writes a vram_insufficient decision row when the phase is parked' do
      result = described_class.parse('phase=render outgoing=brain tenant=down free=8000MiB floor=16GiB verdict=park:vram_insufficient')
      expect do
        described_class.record_insufficient!(goal: goal, result: result)
      end.to change(Growth::Decision, :count).by(1)
      row = Growth::Decision.last
      expect(row.action).to eq('vram_insufficient')
      expect(row.reason).to include('vram_insufficient')
      expect(row.reason).to include('8000MiB')
    end

    it 'writes nothing when the phase is ready' do
      result = described_class.parse('phase=render outgoing=brain tenant=down free=20000MiB floor=16GiB verdict=proceed')
      expect do
        described_class.record_insufficient!(goal: goal, result: result)
      end.not_to change(Growth::Decision, :count)
    end
  end
end
