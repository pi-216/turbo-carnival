# frozen_string_literal: true

require 'rails_helper'

# The live producer of most scheduled posts: render -> NSFW/realism gates ->
# caption -> Scheduling::Post. It used to drop the caption result's metadata, so
# a post that shipped the placeholder 'Fresh look ✨' (or one captioned by the
# fallback model) left no trace beyond a log line.
RSpec.describe Growth::ContentGenerator do
  subject(:generator) { described_class.new(goal: goal, pillar: pillar) }

  let(:persona) { create(:persona) }
  let(:pillar) { create(:content_pillar, persona: persona, name: 'Fashion & Style', weight: 20) }
  let(:goal) { create(:growth_goal, persona: persona) }
  let(:pipeline) { create(:pipeline) }
  let!(:step) { create(:pipeline_step, pipeline: pipeline) }
  let(:image_path) { Rails.root.join('tmp', "gen_spec_#{SecureRandom.hex(6)}.png").to_s }

  let(:gate_ok) { double('scheduler gate', ready?: true, raw: 'claim=busy', claim_state: 'busy', comfyui_up: true) }
  let(:nsfw_ok) { Growth::NsfwGate::Result.new(label: 'normal', nsfw_score: 0.01, flagged: false) }
  let(:realism_ok) { Growth::RealismGate::Result.new(safe: true, aesthetic_score: 5.2, sharpness: 80.0) }
  let(:caption_ok) do
    double('caption result', success?: true, caption: 'A real caption',
                             caption_metadata: { model: 'gemma3:4b', model_selection: 'preferred_not_resident(gemma3:27b)' },
                             errors: double(full_messages: []))
  end

  before do
    FileUtils.mkdir_p(File.dirname(image_path))
    File.binwrite(image_path, 'not-really-a-png')

    allow(Growth::SchedulerGate).to receive(:status).and_return(gate_ok)
    allow(generator).to receive_messages(resolve_pipeline: pipeline, build_prompt: 'a prompt',
                                        poll_for_image: image_path)
    allow(BuildJobPayload).to receive(:call!).and_return(double('payload', job_payload: {}))
    allow(SubmitJob).to receive(:call).and_return(
      double('submit', success?: true, comfyui_job: double('job', id: 1, comfyui_job_id: 'abc'))
    )
    allow(Growth::NsfwGate).to receive(:new).and_return(double('nsfw gate', call: nsfw_ok))
    allow(Growth::RealismGate).to receive(:new).and_return(double('realism gate', call: realism_ok))
    allow(ContentStrategy::HashtagEngine).to receive(:generate).and_return(%w[#one])
  end

  after { FileUtils.rm_f(image_path) }

  describe '#generate_one' do
    it 'schedules the post with the caption provenance recorded on it' do
      allow(PostAutomation::GenerateCaption).to receive(:call).and_return(caption_ok)

      result = generator.generate_one(offset_days: 1)

      expect(result[:success]).to be(true)
      post = Scheduling::Post.find(result[:post_id])
      expect(post.caption).to eq('A real caption')
      expect(post.caption_metadata['model']).to eq('gemma3:4b')
      expect(post.caption_metadata['model_selection']).to eq('preferred_not_resident(gemma3:27b)')
      expect(post.caption_metadata).not_to have_key('placeholder')
      # The post must carry the run that produced it: Growth::RenderSalvage's
      # already_posted? guard reads exactly this column, so a NULL here makes the
      # guard blind to producer-created posts.
      expect(post.pipeline_run_id).to eq(result[:run_id])
    end

    # PRD 0007 A2 (#105): the wardrobe axis value in effect for the render is
    # recorded on the run row, so the reveal level a post carried is auditable
    # without re-deriving it from the prompt.
    it 'records the wardrobe axis level in effect on the run row' do
      allow(PostAutomation::GenerateCaption).to receive(:call).and_return(caption_ok)

      result = generator.generate_one(offset_days: 1)
      run = PipelineRun.find(result[:run_id])

      expect(run.variables['sync_producer']).to eq('Growth::ContentGenerator')
      # The pillar is unconfigured, so the axis FLOOR is in effect and recorded.
      expect(run.variables['wardrobe_level']).to eq(1)
      # B2 (#109): the floor rung covers the areola in text, so the scene
      # negative rides on the run for the graph's {{negative_prompt}} token.
      expect(run.variables['negative_prompt']).to eq(ContentPillars::WardrobeAxis::AREOLA_NEGATIVE)
    end

    it 'records a raised wardrobe level when the pillar is configured' do
      pillar.update!(wardrobe_level: 5)
      allow(ContentPillars::WardrobeAxis).to receive(:validated_tier).and_return(5)
      allow(PostAutomation::GenerateCaption).to receive(:call).and_return(caption_ok)

      result = generator.generate_one(offset_days: 1)
      run = PipelineRun.find(result[:run_id])

      expect(run.variables['wardrobe_level']).to eq(5)
      expect(run.variables['negative_prompt']).to eq(ContentPillars::WardrobeAxis::AREOLA_NEGATIVE)
    end

    # PRD 0007 B2 (#109): the scene negative in effect for the render rides on
    # the run row, from the SAME rung the prompt reads. A scene that exposes
    # the areola in text (a rung not declared to cover) is free of the
    # suppression — the terms are the scene's to carry, not a global default.
    it 'records no scene suppression when the rung in effect exposes the areola in text' do
      pillar.update!(wardrobe_level: 5)
      allow(ContentPillars::WardrobeAxis).to receive(:validated_tier).and_return(5)
      allow(ContentPillars::WardrobeAxis).to receive(:negative_for).and_return('')
      allow(PostAutomation::GenerateCaption).to receive(:call).and_return(caption_ok)

      result = generator.generate_one(offset_days: 1)
      run = PipelineRun.find(result[:run_id])

      expect(run.variables['wardrobe_level']).to eq(5)
      expect(run.variables['negative_prompt']).to eq('')
    end

    it 'ships the placeholder but records why when the caption call fails' do
      allow(PostAutomation::GenerateCaption).to receive(:call).and_return(
        double('caption result', success?: false, caption: nil, caption_metadata: nil,
                                 errors: double(full_messages: [ 'Caption generation failed: timeout' ]))
      )

      result = generator.generate_one(offset_days: 1)

      expect(result[:success]).to be(true)
      post = Scheduling::Post.find(result[:post_id])
      expect(post.caption).to eq('Fresh look ✨')
      expect(post.caption_metadata['placeholder']).to be(true)
      expect(post.caption_metadata['error']).to eq('Caption generation failed: timeout')
    end

    # The producer used to stamp every post with `Time.current + offset_days.days`,
    # so posts made by successive ticks for the same day shared a publishing hour
    # and the hourly publisher released them in one tick (three posts in 24 s on
    # 2026-09-19). The slot must be allocated, and spaced.
    it 'allocates a spaced slot rather than stamping the producing tick clock time' do
      allow(PostAutomation::GenerateCaption).to receive(:call).and_return(caption_ok)

      # A photo can carry only one post (unique index on photo_id+persona_id), so
      # each generation needs its own render output.
      paths = Array.new(2) { Rails.root.join('tmp', "gen_spec_slot_#{SecureRandom.hex(4)}.png").to_s }
      paths.each { |p| File.binwrite(p, 'not-really-a-png') }
      allow(generator).to receive(:poll_for_image) { paths.shift }

      first = Scheduling::Post.find(generator.generate_one(offset_days: 1)[:post_id])
      second = Scheduling::Post.find(generator.generate_one(offset_days: 1)[:post_id])

      expect(first.optimal_time_calculated).to eq(first.scheduled_at)
      expect(second.scheduled_at - first.scheduled_at)
        .to be >= Growth::PostSlotPlanner::SLOT_GAP_MINUTES.minutes
      expect(first.scheduled_at).to be > Time.current
    ensure
      FileUtils.rm_f(paths)
    end

    # A ComfyUI execution error is NOT a timeout, and the difference is the whole
    # diagnosis: until this, every render death was recorded as "render timed out
    # or produced no image" (measured 2026-09-21, run 479: `index is out of bounds
    # for dimension with size 0` -- the workflow's "Bounded Image Crop with Mask"
    # node got an EMPTY CLIPSeg head mask), so the brain's cadence_blocked
    # decision, the ops board and any human saw a cause that named nothing.
    it 'names the ComfyUI execution error instead of reporting a timeout' do
      client = double('comfyui client')
      allow(ComfyuiClient).to receive(:new).and_return(client)
      allow(client).to receive(:get_job_status)
        .and_return(status: 'failed', error: 'index is out of bounds for dimension with size 0')
      allow(generator).to receive(:poll_for_image).and_call_original

      result = generator.generate_one(offset_days: 1)

      expect(result[:success]).to be(false)
      expect(result[:error])
        .to eq('render failed in ComfyUI: index is out of bounds for dimension with size 0')
      expect(PipelineRun.find(result[:run_id]).reject_reason)
        .to eq('render failed in ComfyUI: index is out of bounds for dimension with size 0')
    end

    # A node exception is input-dependent (CLIPSeg found no "head"/"hand" region in
    # THIS sample), and the resubmit draws a fresh seed (`variables["seed"] +
    # comfyui_job.id`), so ONE bounded retry recovers the render instead of losing
    # the slot. The bound is what matters: a prompt that fails deterministically
    # must still fail the run rather than loop.
    it 'retries the render once when a node exception kills it' do
      client = double('comfyui client')
      allow(ComfyuiClient).to receive(:new).and_return(client)
      allow(client).to receive(:get_job_status)
        .and_return(status: 'failed', error: 'index is out of bounds for dimension with size 0')
      allow(generator).to receive(:poll_for_image).and_call_original

      submits = 0
      expect(SubmitJob).to receive(:call).twice do
        submits += 1
        double('submit', success?: true, comfyui_job: double('job', id: submits, comfyui_job_id: "abc#{submits}"))
      end

      result = generator.generate_one(offset_days: 1)

      expect(submits).to eq(2)
      expect(result[:success]).to be(false)
      expect(result[:error])
        .to eq('render failed in ComfyUI: index is out of bounds for dimension with size 0')
    end

    # The retry is gated on a ComfyUI ERROR, not on any failure: a render that
    # simply produced nothing (poll budget exhausted) is a throughput problem, and
    # re-submitting it inside the same tick would only spend more GPU time on it.
    it 'does not re-submit a render that produced no image without a ComfyUI error' do
      allow(generator).to receive(:poll_for_image).and_return(nil)

      expect(SubmitJob).to receive(:call).once.and_return(
        double('submit', success?: true, comfyui_job: double('job', id: 1, comfyui_job_id: 'abc'))
      )

      result = generator.generate_one(offset_days: 1)

      expect(result[:success]).to be(false)
      expect(result[:error]).to eq('render timed out or produced no image')
    end

    # Fallback path: the client's failed payload carries no message (a reconciled
    # orphan, a restarted ComfyUI), so the cause has to come from the record
    # PollJobStatus writes -- and an unknown job must read as "unknown", never as
    # an exception that swallows the failure reason entirely.
    it 'falls back to the job record for the error text, and tolerates an unknown job' do
      create(:comfyui_job, :failed, comfyui_job_id: 'job-xyz',
                                    error_message: 'reconciled: ComfyUI no longer knows prompt job-xyz')

      expect(generator.send(:comfyui_job_error, 'job-xyz'))
        .to eq('reconciled: ComfyUI no longer knows prompt job-xyz')
      expect(generator.send(:comfyui_job_error, 'no-such-job')).to be_nil
    end

    # A job that fails AFTER the poll budget closes (a slow render, a long queue)
    # never reaches poll_for_image's failed-status branch, so the run used to be
    # recorded as "timed out" and the bounded retry was skipped -- silently
    # dropping the two behaviours this class was fixed to provide. The error text
    # is on the ComfyuiJob row (PollJobStatus writes it), so the exhausted poll
    # must read it before giving up.
    it 'reads the job record when the poll budget is exhausted, so the cause and the retry survive a late failure' do
      create(:comfyui_job, :failed, comfyui_job_id: 'job-late',
                                    error_message: 'index is out of bounds for dimension with size 0')
      stub_const('Growth::ContentGenerator::MAX_POLLS', 2)
      stub_const('Growth::ContentGenerator::POLL_INTERVAL', 0)
      client = double('comfyui client')
      allow(ComfyuiClient).to receive(:new).and_return(client)
      allow(client).to receive(:get_job_status).and_return(status: 'not_found')
      allow(generator).to receive(:poll_for_image).and_call_original

      expect(generator.send(:poll_for_image, 'job-late')).to be_nil
      expect(generator.render_error).to eq('index is out of bounds for dimension with size 0')
    end

    # PRD 0007 A1: a flagged render is a NORMAL, SUCCESSFUL render carrying a
    # measurement. It used to be rejected before it could become an asset and
    # recorded as `nsfw_rejected` + `nsfw_purge` (13 renders purged); the score now
    # lands on the run AND on the asset row, and nothing is purged.
    it 'records a flagged NSFW score on the run and the asset instead of rejecting' do
      allow(Growth::NsfwGate).to receive(:new).and_return(
        double('nsfw gate', call: Growth::NsfwGate::Result.new(nsfw_score: 0.97, label: 'nsfw', flagged: true))
      )
      allow(PostAutomation::GenerateCaption).to receive(:call).and_return(caption_ok)

      result = generator.generate_one(offset_days: 1)

      expect(result[:success]).to be(true)

      run = PipelineRun.find(result[:run_id])
      expect(run.quality_metrics['nsfw_score']).to be_within(0.0001).of(0.97)
      expect(run.reject_reason).to be_nil

      photo = ContentPillars::Photo.find(result[:photo_id])
      expect(photo.nsfw_score).to be_within(0.0001).of(0.97)
      expect(photo.nsfw_flagged).to be(true)
      expect(Scheduling::Post.exists?(photo_id: photo.id)).to be(true)

      expect(Growth::Decision.where(action: %w[nsfw_rejected nsfw_purge])).to be_empty
    end

    # Fail-open on the MEASUREMENT (it is not a floor control), but the asset must
    # read as unmeasured rather than as measured-low.
    it 'does not fail the run when the NSFW score could not be measured' do
      allow(Growth::NsfwGate).to receive(:new).and_return(
        double('nsfw gate', call: Growth::NsfwGate::Result.new(error: 'nsfw model dir missing: /nope'))
      )
      allow(PostAutomation::GenerateCaption).to receive(:call).and_return(caption_ok)

      result = generator.generate_one(offset_days: 1)

      expect(result[:success]).to be(true)
      photo = ContentPillars::Photo.find(result[:photo_id])
      expect(photo.nsfw_score).to be_nil
      expect(photo.nsfw_flagged).to be_nil
      expect(Growth::Decision.where(action: %w[nsfw_rejected nsfw_purge])).to be_empty
    end
  end
end
