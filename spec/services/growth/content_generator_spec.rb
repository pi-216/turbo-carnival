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
  let(:nsfw_ok) { Growth::NsfwGate::Result.new(safe: true, label: 'normal', nsfw_score: 0.01) }
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
    end

    it 'ships the placeholder but records why when the caption call fails' do
      allow(PostAutomation::GenerateCaption).to receive(:call).and_return(
        double('caption result', success?: false, caption: nil, caption_metadata: nil,
                                 errors: double(full_messages: ['Caption generation failed: timeout']))
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
  end
end
