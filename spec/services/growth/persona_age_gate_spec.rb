# frozen_string_literal: true

require 'rails_helper'

# The pre-publish age gate (PRD 0007 B1): a queued post whose render reads as a
# minor must not reach Instagram, and a caption-service outage must never stall
# publishing. These examples pin the band parser (pure, so every branch is
# testable), the tier-aware hold matrix (SFW passes when the band top reaches
# 18; the explicit tier passes only on a verified adult band and fails closed
# on ambiguity), the hold write (both publisher clocks cleared, band + tier
# recorded), the fail-open behaviour on an unreadable probe, and the idempotency
# that keeps an hourly caller from paying for the same ~15s vision read twice.
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
  def stub_probe(text: "AGE: 18-25\nTIER: SFW\nCUES: adult proportions", error: nil, model: 'brain')
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

  describe '.parse' do
    it 'parses a numeric band with a tier from the AGE slot' do
      read = described_class.parse("AGE: 17-19\nTIER: EXPLICIT\nCUES: visible areola")

      expect(read.band).to eq([ 17.0, 19.0 ])
      expect(read.tier).to eq(:explicit)
    end

    it 'parses a single age and year phrases as point bands' do
      expect(described_class.parse('She looks about 15 years old.').band).to eq([ 15.0, 15.0 ])
      expect(described_class.parse('AGE: 24 years').band).to eq([ 24.0, 24.0 ])
    end

    it 'parses a bare point in the AGE slot' do
      expect(described_class.parse('AGE: about 18').band).to eq([ 18.0, 18.0 ])
      expect(described_class.parse('AGE: 17').band).to eq([ 17.0, 17.0 ])
    end

    it 'parses "under N" as a band capped below N' do
      expect(described_class.parse('CUES: features suggest a person under 18.').band).to eq([ 0.0, 17.9 ])
    end

    it 'parses "over N" and "N+" as a band above N' do
      expect(described_class.parse('AGE: 18+').band).to eq([ 18.1, 18.1 ])
      expect(described_class.parse('CUES: over 18.').band).to eq([ 18.1, 18.1 ])
    end

    it 'parses "between N and M" as a band' do
      expect(described_class.parse('AGE: between 17 and 19').band).to eq([ 17.0, 19.0 ])
    end

    it 'reads word bands' do
      expect(described_class.parse('AGE: teen').band).to eq([ 13.0, 17.9 ])
      expect(described_class.parse('AGE: child').band).to eq([ 0.0, 12.0 ])
      expect(described_class.parse('AGE: young adult').band).to eq([ 18.0, 65.0 ])
      expect(described_class.parse('a young girl, likely a teenager').band).to eq([ 0.0, 17.9 ])
      expect(described_class.parse('AGE: adult, a young woman in her twenties').band).to eq([ 18.0, 65.0 ])
    end

    it 'reads the band from the AGE slot, not from adjectives in the CUES prose' do
      # Measured 2026-10 probe read: the slot says teen, the cues say "youthful
      # ... minor". The band must stay entirely below the floor -- one prose
      # adjective ("youthful") must not widen it into 18 and publish a minor.
      read = described_class.parse("AGE: teen\nCUES: smooth unlined skin, full rounded cheeks, soft " \
                                   'youthful jawline, and slender proportions indicate a minor.')

      expect(read.band).to eq([ 13.0, 17.9 ])
      expect(described_class.verdict(read.band)).to eq(:juvenile)
    end

    it 'takes the AGE slot over the prose when both carry a band' do
      # Measured 2026-09-21 on a queued render: the slot says "young adult" while
      # the cues say "late teen or early twenties". B1: the slot is the read.
      read = described_class.parse("AGE: young adult\nCUES: Her skin suggests a late teen or early twenties age.")

      expect(read.band).to eq([ 18.0, 65.0 ])
      expect(described_class.verdict(read.band)).to eq(:adult)
    end

    it 'falls back to the prose when the AGE slot is missing or empty' do
      expect(described_class.parse('She looks 17-19 to me.').band).to eq([ 17.0, 19.0 ])
      read = described_class.parse("AGE: \nCUES: she reads mid-teens.")
      expect(read.band).to eq([ 13.0, 17.9 ])
      expect(described_class.verdict(read.band)).to eq(:juvenile)
    end

    it 'reads a no-person read from the AGE slot' do
      expect(described_class.parse('AGE: none').band).to eq(:none)
      # "none" in the CUES prose must not skip the age check.
      expect(described_class.parse("AGE: 17-19\nCUES: none of the visible details.").band).to eq([ 17.0, 19.0 ])
    end

    it 'returns an unparseable band rather than guessing' do
      expect(described_class.parse('').band).to be_nil
      expect(described_class.parse('The image shows a street at dusk.').band).to be_nil
    end

    it 'parses the tier line, failing to :unknown when absent' do
      expect(described_class.parse("TIER: SFW").tier).to eq(:sfw)
      expect(described_class.parse("TIER: EXPLICIT").tier).to eq(:explicit)
      expect(described_class.parse('TIER: not explicit, covered swimwear').tier).to eq(:sfw)
      expect(described_class.parse("AGE: 17-19\nCUES: soft features").tier).to eq(:unknown)
      expect(described_class.parse("TIER: a question mark").tier).to eq(:unknown)
    end
  end

  describe '.verdict' do
    it 'is juvenile when the band top is below 18' do
      expect(described_class.verdict([ 0.0, 12.0 ])).to eq(:juvenile)
      expect(described_class.verdict([ 13.0, 17.9 ])).to eq(:juvenile)
      expect(described_class.verdict([ 16.0, 17.0 ])).to eq(:juvenile)
    end

    it 'is adult when the band bottom is at or above 18' do
      expect(described_class.verdict([ 18.0, 24.0 ])).to eq(:adult)
      expect(described_class.verdict([ 18.0, 65.0 ])).to eq(:adult)
    end

    it 'is ambiguous when the band spans 18' do
      expect(described_class.verdict([ 17.0, 19.0 ])).to eq(:ambiguous)
      expect(described_class.verdict([ 16.0, 19.0 ])).to eq(:ambiguous)
    end

    it 'maps no-person and unparseable bands' do
      expect(described_class.verdict(:none)).to eq(:no_person)
      expect(described_class.verdict(nil)).to eq(:unknown)
    end
  end

  describe '.hold?' do
    it 'holds a juvenile band at every tier (B1 row 1)' do
      expect(described_class.hold?(:juvenile, :sfw)).to be(true)
      expect(described_class.hold?(:juvenile, :explicit)).to be(true)
      expect(described_class.hold?(:juvenile, :unknown)).to be(true)
    end

    it 'publishes an ambiguous band at the SFW tier (B1 row 2)' do
      expect(described_class.hold?(:ambiguous, :sfw)).to be(false)
    end

    it 'holds an ambiguous band at the explicit tier, fail-closed on unknown tier (B1 row 2)' do
      expect(described_class.hold?(:ambiguous, :explicit)).to be(true)
      expect(described_class.hold?(:ambiguous, :unknown)).to be(true)
    end

    it 'holds an unparseable band at the explicit and unknown tiers (fail-closed on ambiguity)' do
      expect(described_class.hold?(:unknown, :explicit)).to be(true)
      expect(described_class.hold?(:unknown, :unknown)).to be(true)
    end

    it 'leaves an unparseable band unmarked at the SFW tier (not evidence; re-read)' do
      expect(described_class.hold?(:unknown, :sfw)).to be(false)
    end

    it 'publishes a confident adult or no-person band at every tier (B1 row 3)' do
      expect(described_class.hold?(:adult, :explicit)).to be(false)
      expect(described_class.hold?(:adult, :sfw)).to be(false)
      expect(described_class.hold?(:no_person, :explicit)).to be(false)
    end
  end

  describe '.call' do
    it 'reports a hold in dry run and writes NOTHING' do
      post = queued_post
      stub_probe(text: "AGE: 17-19\nTIER: EXPLICIT\nCUES: visible areola")

      results = described_class.call(persona: persona, dry_run: true)

      expect(results.map(&:outcome)).to include(:would_hold)
      post.reload
      expect(post.scheduled_at).to be_present
      expect(post.caption_metadata).to be_blank
      expect(Growth::Decision.where(action: 'age_gate_hold').count).to eq(0)
    end

    it 'clears BOTH publisher clocks on a juvenile read and records the band and tier' do
      post = queued_post
      stub_probe(text: "AGE: 12-15\nTIER: SFW\nCUES: childlike features")

      results = described_class.call(persona: persona, dry_run: false)

      expect(results.first.outcome).to eq(:held)
      expect(results.first.band).to eq([ 12.0, 15.0 ])
      post.reload
      expect(post.scheduled_at).to be_nil
      expect(post.optimal_time_calculated).to be_nil
      expect(post.status).to eq('scheduled') # state machine untouched
      expect(post.caption_metadata['age_gate']['verdict']).to eq('juvenile')
      expect(post.caption_metadata['age_gate']['band']).to eq([ 12.0, 15.0 ])
      expect(post.caption_metadata['age_gate']['tier']).to eq('sfw')
      expect(post.caption_metadata['age_gate']['held']).to be(true)
      expect(post.caption_metadata['age_gate']['model']).to eq('brain')
      expect(Growth::Decision.where(action: 'age_gate_hold').count).to eq(1)
    end

    it 'PUBLISHES a band that spans 18 at the SFW tier and records the read' do
      post = queued_post
      stub_probe(text: "AGE: 17-19\nTIER: SFW\nCUES: soft youthful features")

      results = described_class.call(persona: persona, dry_run: false)

      expect(results.first.outcome).to eq(:cleared)
      post.reload
      expect(post.scheduled_at).to be_present
      expect(post.caption_metadata['age_gate']['verdict']).to eq('ambiguous')
      expect(post.caption_metadata['age_gate']['band']).to eq([ 17.0, 19.0 ])
      expect(post.caption_metadata['age_gate']['tier']).to eq('sfw')
      expect(post.caption_metadata['age_gate']['held']).to be(false)
      # Decided, so the next tick does not pay for the probe again.
      expect(described_class.new(persona: persona).candidates(limit: 10)).to be_empty
    end

    it 'HOLDS a band that spans 18 at the explicit tier (fail-closed)' do
      post = queued_post
      stub_probe(text: "AGE: 17-19\nTIER: EXPLICIT\nCUES: visible areola")

      results = described_class.call(persona: persona, dry_run: false)

      expect(results.first.outcome).to eq(:held)
      post.reload
      expect(post.scheduled_at).to be_nil
      expect(post.optimal_time_calculated).to be_nil
      expect(post.caption_metadata['age_gate']['verdict']).to eq('ambiguous')
      expect(post.caption_metadata['age_gate']['tier']).to eq('explicit')
      expect(Growth::Decision.where(action: 'age_gate_hold').count).to eq(1)
    end

    it 'holds when the tier is unknown and the band spans 18 (fail-closed)' do
      post = queued_post
      stub_probe(text: "AGE: 17-19\nCUES: soft youthful features")

      results = described_class.call(persona: persona, dry_run: false)

      expect(results.first.outcome).to eq(:held)
      expect(post.reload.caption_metadata['age_gate']['tier']).to eq('unknown')
    end

    it 'HOLDS an unparseable read at the explicit tier (fail-closed on ambiguity)' do
      post = queued_post
      stub_probe(text: "The render shows a person, wardrobe is revealing. I cannot settle the age.")

      results = described_class.call(persona: persona, dry_run: false)

      expect(results.first.outcome).to eq(:held)
      post.reload
      expect(post.scheduled_at).to be_nil
      expect(post.caption_metadata['age_gate']['verdict']).to eq('unknown')
      expect(post.caption_metadata['age_gate']['held']).to be(true)
    end

    it 'leaves an unparseable read unmarked and undecided at the SFW tier (fail-open, re-read)' do
      post = queued_post
      stub_probe(text: "AGE: ?\nTIER: SFW\nCUES: the render is a street at dusk")

      results = described_class.call(persona: persona, dry_run: false)

      expect(results.first.outcome).to eq(:undecided)
      post.reload
      expect(post.scheduled_at).to be_present
      expect(post.caption_metadata).to be_blank
      # Not marked, so the next tick reads it again.
      expect(described_class.new(persona: persona).candidates(limit: 10).map(&:id)).to eq([ post.id ])
    end

    it 'leaves a confident adult render alone at the explicit tier and records the read' do
      post = queued_post
      stub_probe(text: "AGE: 18-25\nTIER: EXPLICIT\nCUES: adult proportions")

      described_class.call(persona: persona, dry_run: false)

      post.reload
      expect(post.scheduled_at).to be_present
      expect(post.caption_metadata['age_gate']['verdict']).to eq('adult')
      expect(described_class.new(persona: persona).candidates(limit: 10)).to be_empty
    end

    it 'publishes a no-person read at every tier and records it' do
      post = queued_post
      stub_probe(text: "AGE: none\nTIER: EXPLICIT\nCUES: landscape only")

      results = described_class.call(persona: persona, dry_run: false)

      expect(results.first.outcome).to eq(:cleared)
      post.reload
      expect(post.caption_metadata['age_gate']['verdict']).to eq('no_person')
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
      stub_probe(text: "AGE: 12-15\nTIER: SFW\nCUES: childlike features")

      expect(described_class.call(persona: persona, dry_run: false)).to be_empty
    end

    it 'logs the unreadable-read count so a serving-home outage is visible to the weekly review' do
      queued_post
      queued_post
      stub_probe(text: '', error: 'brain_unavailable')

      allow(Rails.logger).to receive(:warn)

      results = described_class.call(persona: persona, dry_run: false)

      expect(results.map(&:outcome)).to all(eq(:skipped))
      expect(Rails.logger).to have_received(:warn).with(/2 unreadable read\(s\) this run/)
    end

    it 'checks the nearest slot first' do
      soon = queued_post(slot: 1.day.from_now)
      later = queued_post(slot: 3.days.from_now)
      stub_probe

      expect(described_class.new(persona: persona).candidates(limit: 10).map(&:id)).to eq([ soon.id, later.id ])
    end
  end

  describe '.hold!' do
    it 'holds a named post through the same write path and logs the slot it came from' do
      post = queued_post

      result = described_class.hold!(post: post, read: 'independent read: early teens', reason: 'unresolved read')

      expect(result.outcome).to eq(:held)
      expect(result.band).to eq([ 11.0, 17.9 ])
      post.reload
      expect(post.scheduled_at).to be_nil
      expect(post.optimal_time_calculated).to be_nil
      expect(post.caption_metadata['age_gate']['verdict']).to eq('juvenile')
      expect(post.caption_metadata['age_gate']['held']).to be(true)
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

    it 'refuses a post that has no future slot' do
      post = queued_post
      post.update_columns(scheduled_at: nil, optimal_time_calculated: nil)

      expect { described_class.hold!(post: post, read: 'x', reason: 'y') }
        .to raise_error(ArgumentError, /no future slot/)
    end
  end
end
