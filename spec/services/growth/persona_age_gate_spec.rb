# frozen_string_literal: true

require 'rails_helper'

# The pre-publish age gate: a queued post whose render reads as a minor must not
# reach Instagram, and a caption-service outage must never stall publishing.
# These examples pin the classifier (pure, so every branch is testable), the
# hold write (both publisher clocks cleared, metadata recorded), the fail-open
# behaviour on an unreadable probe, and the idempotency that keeps an hourly
# caller from paying for the same ~15s vision read twice.
RSpec.describe Growth::PersonaAgeGate do
  let(:persona) { create(:persona) }
  let(:pillar) { create(:content_pillar, persona: persona) }
  let!(:goal) { create(:growth_goal, persona: persona) }

  def queued_post(slot: 2.days.from_now)
    photo = ContentPillars::Photo.create!(persona: persona, path: "spec-#{SecureRandom.hex(4)}.png",
                                          content_pillar: pillar)
    Scheduling::Post.create!(persona: persona, photo: photo, caption: 'x', status: 'scheduled',
                             scheduled_at: slot, optimal_time_calculated: slot)
  end

  # Replaces the vision probe: no socket, and the answer is whatever the example
  # wants. `ok?`/`text`/`model`/`error` are the whole surface the gate uses.
  def stub_probe(text: 'AGE: adult', error: nil, model: 'gemma3:4b')
    result = CaptionGeneration::VisionProbe::Result.new(text: text, model: model, error: error)
    klass = Class.new do
      define_method(:ask) { result }
      define_method(:ok?) { result.ok? }
      define_method(:text) { result.text }
      define_method(:model) { result.model }
      define_method(:model_selection) { 'stubbed' }
      define_method(:error) { result.error }
    end
    klass.define_singleton_method(:ask) { |**| klass.new }
    stub_const('CaptionGeneration::VisionProbe', klass)
  end

  describe '.classify' do
    it 'reads a juvenile AGE line as juvenile' do
      expect(described_class.classify('AGE: teen')).to eq(:juvenile)
      expect(described_class.classify('AGE: child')).to eq(:juvenile)
      expect(described_class.classify('AGE: none')).to eq(:no_person)
    end

    it 'reads an adult AGE line as adult' do
      expect(described_class.classify('AGE: young adult')).to eq(:adult)
      expect(described_class.classify('AGE: middle-aged')).to eq(:adult)
    end

    it 'holds when the CUES name a teen cue even though the AGE line says adult' do
      # Measured 2026-09-21 on a queued render: the AGE line said "young adult"
      # while the cues said "late teen or early twenties". Ambiguity holds.
      read = "AGE: young adult\nCUES: Her skin suggests a late teen or early twenties age."
      expect(described_class.classify(read)).to eq(:juvenile)
    end

    it 'prefers an explicit numeric age over prose' do
      expect(described_class.classify('She looks about 15 years old.')).to eq(:juvenile)
      expect(described_class.classify('She looks about 24 years old.')).to eq(:adult)
    end

    it 'classifies a free-form juvenile description with no AGE line' do
      expect(described_class.classify('a young girl, likely a teenager')).to eq(:juvenile)
    end

    it 'returns unknown rather than guessing' do
      expect(described_class.classify('')).to eq(:unknown)
      expect(described_class.classify('The image shows a street at dusk.')).to eq(:unknown)
    end

    it 'does not treat "young woman" as juvenile' do
      expect(described_class.classify('AGE: adult, a young woman in her twenties')).to eq(:adult)
    end
  end

  describe '.call' do
    it 'reports a hold in dry run and writes NOTHING' do
      post = queued_post
      stub_probe(text: 'AGE: teen')

      results = described_class.call(persona: persona, dry_run: true)

      expect(results.map(&:outcome)).to include(:would_hold)
      post.reload
      expect(post.scheduled_at).to be_present
      expect(post.caption_metadata).to be_blank
      expect(Growth::Decision.where(action: 'age_gate_hold').count).to eq(0)
    end

    it 'clears BOTH publisher clocks on a juvenile read, and records the read' do
      post = queued_post
      stub_probe(text: 'AGE: teen')

      results = described_class.call(persona: persona, dry_run: false)

      expect(results.first.outcome).to eq(:held)
      post.reload
      expect(post.scheduled_at).to be_nil
      expect(post.optimal_time_calculated).to be_nil
      expect(post.status).to eq('scheduled') # state machine untouched
      expect(post.caption_metadata['age_gate']['verdict']).to eq('juvenile')
      expect(post.caption_metadata['age_gate']['held']).to be(true)
      expect(Growth::Decision.where(action: 'age_gate_hold').count).to eq(1)
    end

    it 'leaves an adult render alone and records the read so it is not re-probed' do
      post = queued_post
      stub_probe(text: 'AGE: adult')

      described_class.call(persona: persona, dry_run: false)

      post.reload
      expect(post.scheduled_at).to be_present
      expect(post.caption_metadata['age_gate']['verdict']).to eq('adult')
      expect(described_class.new(persona: persona).candidates(limit: 10)).to be_empty
    end

    it 'FAILS OPEN on an unreadable probe: nothing held, nothing recorded, retried next tick' do
      post = queued_post
      stub_probe(text: '', error: 'Faraday::ConnectionFailed: no route to host')

      results = described_class.call(persona: persona, dry_run: false)

      expect(results.first.outcome).to eq(:skipped)
      post.reload
      expect(post.scheduled_at).to be_present
      expect(post.caption_metadata).to be_blank
      # Not marked, so the next tick reads it again.
      expect(described_class.new(persona: persona).candidates(limit: 10).map(&:id)).to eq([ post.id ])
    end

    it 'ignores posts whose slot has already passed' do
      queued_post(slot: 1.hour.ago)
      stub_probe(text: 'AGE: teen')

      expect(described_class.call(persona: persona, dry_run: false)).to be_empty
    end

    it 'checks the nearest slot first' do
      soon = queued_post(slot: 1.day.from_now)
      later = queued_post(slot: 3.days.from_now)
      stub_probe(text: 'AGE: adult')

      expect(described_class.new(persona: persona).candidates(limit: 10).map(&:id)).to eq([ soon.id, later.id ])
    end
  end

  describe '.hold!' do
    it 'holds a named post through the same write path and logs the slot it came from' do
      post = queued_post

      result = described_class.hold!(post: post, read: 'independent read: early teens', reason: 'unresolved read')

      expect(result.outcome).to eq(:held)
      post.reload
      expect(post.scheduled_at).to be_nil
      expect(post.optimal_time_calculated).to be_nil
      decision = Growth::Decision.find_by(action: 'age_gate_hold')
      expect(decision.reason).to include("post #{post.id}")
      expect(decision.reason).to include('unresolved read')
    end

    it 'refuses a post that has already published' do
      post = queued_post
      post.update_columns(status: 'posted', posted_at: Time.current)

      expect { described_class.hold!(post: post, read: 'x', reason: 'y') }
        .to raise_error(ArgumentError, /not unpublished/)
    end
  end
end
