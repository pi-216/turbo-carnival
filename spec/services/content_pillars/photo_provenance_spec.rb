# frozen_string_literal: true

require 'rails_helper'

# The synthetic mark a render carries into the database
# (openspec/changes/add-synthetic-provenance, task 1.3).
#
# These are pure decisions, so they are tested without a render: the point is
# that the hash records what the run ACTUALLY carries and says nothing about what
# it does not. Pillar 2 mandates base_model/seed/prompt_hash on every render, but
# the growth path persists only `sync_producer` today, so an invented value would
# be worse than an absent one.
RSpec.describe ContentPillars::PhotoProvenance do
  describe '.for_run' do
    it 'marks the render synthetic and records the attribution it actually has' do
      run = double(
        'run',
        id: 476,
        prompt: 'a beach scene',
        variables: { 'sync_producer' => 'Growth::ContentGenerator', 'seed' => 12_345 },
        quality_metrics: { 'nsfw_score' => 0.0001, 'aesthetic_score' => 6.37 }
      )

      mark = described_class.for_run(run)

      expect(mark['digital_source_type']).to eq('trainedAlgorithmicMedia')
      expect(mark['source']).to eq('render')
      expect(mark['embedded']).to be(false)
      expect(mark['run_id']).to eq(476)
      expect(mark['seed']).to eq(12_345)
      expect(mark['prompt_hash']).to eq(Digest::SHA256.hexdigest('a beach scene'))
      expect(mark['quality_metrics']).to eq('nsfw_score' => 0.0001, 'aesthetic_score' => 6.37)
      expect(Time.iso8601(mark['recorded_at'])).to be_a(Time)
    end

    it 'omits the attribution fields the run does not carry, rather than inventing them' do
      run = double('run', id: 9, prompt: nil, variables: { 'sync_producer' => 'Growth::ContentGenerator' },
                          quality_metrics: {})

      mark = described_class.for_run(run)

      expect(mark).not_to have_key('seed')
      expect(mark).not_to have_key('base_model')
      expect(mark).not_to have_key('prompt_hash')
      expect(mark).not_to have_key('quality_metrics')
    end

    it 'tolerates a run that answers none of the attribution questions' do
      mark = described_class.for_run(double('bare run', id: 1))

      expect(mark['run_id']).to eq(1)
      expect(mark['embedded']).to be(false)
      expect(mark).not_to have_key('seed')
    end

    it 'accepts a nil run (a render whose run record is gone)' do
      mark = described_class.for_run(nil)

      expect(mark['digital_source_type']).to eq('trainedAlgorithmicMedia')
      expect(mark).not_to have_key('run_id')
    end
  end

  describe '.backfilled' do
    it 'marks a pre-existing photo synthetic and says nothing was embedded' do
      mark = described_class.backfilled

      expect(mark['digital_source_type']).to eq('trainedAlgorithmicMedia')
      expect(mark['source']).to eq('backfill')
      expect(mark['embedded']).to be(false)
      expect(mark['note']).to be_present
    end
  end
end
