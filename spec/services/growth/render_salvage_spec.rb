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
    Growth::NsfwGate::Result.new(label: 'normal', nsfw_score: 0.01, flagged: false)
  end
  let(:realism_ok) do
    Growth::RealismGate::Result.new(aesthetic_score: 5.2, sharpness: 80.0, flagged: false)
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
    # The abandonment clock is the CANDIDATE's created_at (the render landing),
    # so the fixture has to age it too -- see abandoned_candidates.
    candidate.update_column(:created_at, 2.hours.ago)

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

    it 'is idempotent — a path that already has a POST is the marker, so a second call recovers nothing' do
      expect(salvage.call(limit: 3).recovered).to eq(1)

      second = salvage.call(limit: 3)
      expect(second.recovered).to eq(0)
      expect(second.examined).to eq(0)
      expect(Scheduling::Post.where(strategy_name: 'render-salvage').count).to eq(1)
    end

    # Regression (2026-09-24): the producer imports the photo and only THEN
    # captions it (a slow Ollama call) before creating the post, so a kill in
    # that window leaves a Photo row and no post. The candidate-level guard used
    # to refuse on Photo-existence, which classified that interrupted producer
    # as finished and silently discarded the paid render. Only a POST proves
    # completion.
    it 'finishes a producer that was killed AFTER importing the photo but BEFORE scheduling' do
      orphan = ContentPillars::Photo.create!(persona: persona, content_pillar: pillar,
                                             path: image_path, image_candidate: candidate)

      result = salvage.call(limit: 3)

      expect(result.recovered).to eq(1)
      expect(ContentPillars::Photo.where(path: image_path).count).to eq(1)
      post = Scheduling::Post.find(result.post_ids.first)
      expect(post.photo_id).to eq(orphan.id)
      expect(post.pipeline_run_id).to eq(run.id)
    end

    it 'does not double-post a path whose post already exists without the run link' do
      photo = ContentPillars::Photo.create!(persona: persona, content_pillar: pillar, path: image_path)
      Scheduling::Post.create!(persona: persona, photo: photo, caption: 'already scheduled',
                               status: 'scheduled', scheduled_at: 1.day.from_now)

      result = salvage.call(limit: 3)

      expect(result.recovered).to eq(0)
      expect(result.examined).to eq(0)
    end

    it 'never races a live producer: a render that just landed is skipped' do
      candidate.update_column(:created_at, 2.minutes.ago)

      result = salvage.call(limit: 3)

      expect(result.examined).to eq(0)
      expect(Scheduling::Post.where(strategy_name: 'render-salvage').count).to eq(0)
    end

    # Regression (2026-09-22): ReconcileStaleRuns writes a terminal status onto
    # exactly these runs and BUMPED their updated_at, which used to restart the
    # grace and make a dead producer's finished render unrecoverable for another
    # 30 min per reconcile. Our own bookkeeping must not move the clock.
    it 'recovers when our own reconciler touched the run after the render landed' do
      run.update_column(:updated_at, 1.minute.ago)

      result = salvage.call(limit: 3)

      expect(result.recovered).to eq(1)
      expect(Scheduling::Post.where(strategy_name: 'render-salvage').count).to eq(1)
    end

    # PRD 0007 A1: a flagged recovered render is still PAID-FOR queue content. The
    # score is re-measured and carried onto the asset row (backfill included, since
    # this is the path where the Photo row often already exists) and nothing is
    # rejected for it.
    it 'records the re-measured NSFW score on the recovered asset instead of rejecting' do
      allow(Growth::NsfwGate).to receive(:new).and_return(
        double('nsfw_gate', call: Growth::NsfwGate::Result.new(nsfw_score: 0.97, label: 'nsfw', flagged: true))
      )

      result = salvage.call(limit: 3)

      expect(result.recovered).to eq(1)
      expect(result.rejected).to eq(0)
      expect(Scheduling::Post.where(strategy_name: 'render-salvage').count).to eq(1)
      photo = ContentPillars::Photo.find_by(path: image_path)
      expect(photo.nsfw_score).to be_within(0.0001).of(0.97)
      expect(photo.nsfw_flagged).to be(true)
      expect(Growth::Decision.where(action: 'salvage_rejected')).to be_empty
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

    # A recovered post that shipped the placeholder must stay countable: the log
    # line ages out, so the reason has to live on the post.
    it 'persists the caption metadata on the recovered post' do
      allow(captioner).to receive(:call).and_return(
        double('caption result', success?: true, caption: 'Recovered caption',
               caption_metadata: { model: 'gemma3:4b', model_selection: 'preferred_not_resident(gemma3:27b)' },
               errors: double(full_messages: []))
      )

      post = Scheduling::Post.find(salvage.call(limit: 3).post_ids.first)

      expect(post.caption_metadata['model']).to eq('gemma3:4b')
      expect(post.caption_metadata['model_selection']).to eq('preferred_not_resident(gemma3:27b)')
      expect(post.caption_metadata).not_to have_key('placeholder')
    end

    it 'records a placeholder caption on the post when the captioner fails' do
      allow(captioner).to receive(:call).and_return(
        double('caption result', success?: false, caption: nil, caption_metadata: nil,
               errors: double(full_messages: [ 'Caption generation failed: timeout' ]))
      )

      post = Scheduling::Post.find(salvage.call(limit: 3).post_ids.first)

      expect(post.caption).to eq('Fresh look ✨')
      expect(post.caption_metadata['placeholder']).to be(true)
      expect(post.caption_metadata['error']).to eq('Caption generation failed: timeout')
    end

    it 'still schedules the post when the captioner raises' do
      allow(captioner).to receive(:call).and_raise(StandardError, 'ollama exploded')

      post = Scheduling::Post.find(salvage.call(limit: 3).post_ids.first)

      expect(post.caption).to eq('Fresh look ✨')
      expect(post.caption_metadata['error']).to eq('captioner raised before returning a result')
    end

    # PRD 0007 B3: the realism re-run no longer vetoes, so a recovered render that
    # scores below the selection defaults is still PAID-FOR queue content. The scores
    # ride the run and the asset row, where the selector ranks it last.
    it 'recovers a below-default render instead of rejecting it' do
      allow(Growth::RealismGate).to receive(:new).and_return(
        double('realism_gate',
               call: Growth::RealismGate::Result.new(aesthetic_score: 3.4, sharpness: 11.0, flagged: true))
      )

      result = salvage.call(limit: 3)

      expect(result.recovered).to eq(1)
      expect(result.rejected).to eq(0)

      post = Scheduling::Post.find(result.post_ids.first)
      expect(post.photo.aesthetic_score).to eq(3.4)
      expect(post.photo.sharpness).to eq(11.0)
      expect(run.reload.quality_metrics['aesthetic_score']).to eq(3.4)
      expect(Growth::Decision.where(action: 'salvage_rejected')).to be_empty
    end
  end
end
