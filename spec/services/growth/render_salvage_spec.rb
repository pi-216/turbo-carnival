# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Growth::RenderSalvage do
  subject(:salvage) { described_class.new(goal: goal, captioner: captioner) }

  let(:persona) { create(:persona) }
  let!(:pillar) { create(:content_pillar, persona: persona, name: 'Fashion & Style', weight: 20) }
  let(:goal) { create(:growth_goal, persona: persona) }
  let(:pipeline) { create(:pipeline) }
  let(:step) { create(:pipeline_step, pipeline: pipeline) }
  let(:captioner) { double('captioner') }

  let(:image_path) { Rails.root.join('tmp', "salvage_spec_#{SecureRandom.hex(6)}.png").to_s }

  let(:nsfw_ok) do
    Growth::NsfwGate::Result.new(safe: true, label: 'normal', nsfw_score: 0.01)
  end
  let(:realism_ok) do
    Growth::RealismGate::Result.new(safe: true, aesthetic_score: 5.2, sharpness: 80.0)
  end

  # A sync-produced run that a killed producer abandoned: render finished, run
  # untouched for well past the abandonment grace, image still on disk.
  let!(:run) do
    create(:pipeline_run, pipeline: pipeline, persona: persona, content_pillar: pillar,
                          status: 'failed',
                          variables: { 'sync_producer' => 'Growth::ContentGenerator' })
  end
  let!(:candidate) do
    create(:image_candidate, pipeline_step: step, pipeline_run: run, image_path: image_path)
  end

  before do
    FileUtils.mkdir_p(File.dirname(image_path))
    File.binwrite(image_path, 'not-really-a-png')
    run.update_column(:updated_at, 2.hours.ago)

    allow(Growth::NsfwGate).to receive(:new).and_return(double('nsfw_gate', call: nsfw_ok))
    allow(Growth::RealismGate).to receive(:new).and_return(double('realism_gate', call: realism_ok))
    allow(captioner).to receive(:call).and_return(double(success?: true, caption: 'Recovered caption'))
    allow(ContentStrategy::HashtagEngine).to receive(:generate).and_return(%w[#recovered])
  end

  after { FileUtils.rm_f(image_path) }

  describe '#call' do
    it 'finishes the pipeline for an abandoned render: import, caption, schedule' do
      result = salvage.call(limit: 3)

      expect(result.recovered).to eq(1)
      expect(result.post_ids.size).to eq(1)

      post = Scheduling::Post.find(result.post_ids.first)
      expect(post.status).to eq('scheduled')
      expect(post.strategy_name).to eq('render-salvage')
      expect(post.caption).to eq('Recovered caption')
      expect(post.hashtags).to eq(%w[#recovered])
      expect(post.pipeline_run_id).to eq(run.id)
      expect(post.photo.path).to eq(image_path)

      expect(run.reload.quality_metrics['salvaged_post_id']).to eq(post.id)
      expect(Growth::Decision.where(action: 'salvage_recovered').count).to eq(1)
    end

    it 'is idempotent — the Photo row is the marker, so a second call recovers nothing' do
      expect(salvage.call(limit: 3).recovered).to eq(1)

      second = salvage.call(limit: 3)
      expect(second.recovered).to eq(0)
      expect(second.examined).to eq(0)
      expect(Scheduling::Post.where(strategy_name: 'render-salvage').count).to eq(1)
    end

    it 'never races a live producer: a run untouched inside the grace is skipped' do
      run.update_column(:updated_at, 2.minutes.ago)

      result = salvage.call(limit: 3)

      expect(result.examined).to eq(0)
      expect(Scheduling::Post.where(strategy_name: 'render-salvage').count).to eq(0)
    end

    it 're-runs the NSFW gate and records a rejection instead of scheduling' do
      allow(Growth::NsfwGate).to receive(:new).and_return(
        double('nsfw_gate', call: Growth::NsfwGate::Result.new(safe: false, label: 'nsfw', nsfw_score: 0.97))
      )

      result = salvage.call(limit: 3)

      expect(result.recovered).to eq(0)
      expect(result.rejected).to eq(1)
      expect(Scheduling::Post.where(strategy_name: 'render-salvage').count).to eq(0)
      expect(ContentPillars::Photo.exists?(path: image_path)).to be(false)
      expect(Growth::Decision.where(action: 'salvage_rejected').count).to eq(1)
    end

    it 'does not re-gate a run whose producer already rejected it' do
      run.update!(reject_reason: 'nsfw_rejected (label=lingerie score=0.97)')

      result = salvage.call(limit: 3)

      expect(result.examined).to eq(0)
      expect(Growth::Decision.where(action: 'salvage_rejected').count).to eq(0)
    end

    it 'ignores runs that are not sync-produced' do
      run.update!(variables: { 'prompt' => 'async run' })

      expect(salvage.call(limit: 3).examined).to eq(0)
    end

    it 'does nothing when there is no shortfall budget' do
      expect(salvage.call(limit: 0).recovered).to eq(0)
      expect(Scheduling::Post.where(strategy_name: 'render-salvage').count).to eq(0)
    end

    it 'skips a candidate whose image file is gone' do
      FileUtils.rm_f(image_path)

      result = salvage.call(limit: 3)

      expect(result.examined).to eq(0)
    end
  end
end
