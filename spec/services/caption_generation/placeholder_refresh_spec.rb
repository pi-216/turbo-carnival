# frozen_string_literal: true

require 'rails_helper'

# The caption ladder fixed WHY the caption call fails, but the placeholder it had
# already written stayed in the queue: 5 unpublished posts still carried
# 'Fresh look ✨' on 2026-09-20, 4 of them due inside two hours. These examples
# pin the two properties that make the repair safe to run: it only ever touches
# UNPUBLISHED placeholder posts, and it writes nothing unless asked.
RSpec.describe CaptionGeneration::PlaceholderRefresh do
  let(:now) { Time.zone.local(2026, 9, 20, 12, 0) }
  let(:persona) { create(:persona) }
  let(:pillar) { create(:content_pillar, persona: persona) }

  def post_at(caption:, at:, status: 'scheduled')
    photo = ContentPillars::Photo.create!(persona: persona, path: "spec-#{SecureRandom.hex(4)}.png",
                                          content_pillar: pillar)
    Scheduling::Post.create!(persona: persona, photo: photo, caption: caption, status: status,
                             scheduled_at: at, optimal_time_calculated: at)
  end

  def ok_result(text)
    Struct.new(:caption, :caption_metadata) { def success? = true }
          .new(text, { model: 'stub', model_selection: 'stub' })
  end

  def bad_result
    Struct.new(:errors, :caption_metadata) do
      def success? = false
      def full_error_message = 'stub failure'
    end.new([], {})
  end

  describe '#candidates' do
    it 'selects only unpublished posts still carrying the placeholder' do
      placeholder = post_at(caption: 'Fresh look ✨', at: now + 1.hour)
      post_at(caption: 'a real caption', at: now + 2.hours)
      post_at(caption: 'Fresh look ✨', at: now - 1.hour) # already due: the publisher's problem
      post_at(caption: 'Fresh look ✨', at: now + 3.hours, status: 'posted')

      expect(described_class.new(now: now).candidates.map(&:id)).to eq([placeholder.id])
    end

    it 'includes an already-due placeholder when asked -- the publisher runs this ' \
       'immediately before sending, so a late tick must not publish the artifact' do
      future = post_at(caption: 'Fresh look ✨', at: now + 1.hour)
      due = post_at(caption: 'Fresh look ✨', at: now - 1.hour)
      post_at(caption: 'Fresh look ✨', at: now + 3.hours, status: 'posted')

      ids = described_class.new(now: now).candidates(include_due: true).map(&:id)

      expect(ids).to contain_exactly(future.id, due.id)
    end
  end

  describe '.call' do
    it 'writes nothing on a dry run' do
      post = post_at(caption: 'Fresh look ✨', at: now + 1.hour)
      expect(PostAutomation::GenerateCaption).not_to receive(:call)

      results = described_class.call(dry_run: true, now: now)

      expect(results.map(&:outcome)).to eq([:would_refresh])
      expect(post.reload.caption).to eq('Fresh look ✨')
    end

    it 'replaces the caption and records provenance when the captioner answers' do
      post = post_at(caption: 'Fresh look ✨', at: now + 1.hour)
      allow(PostAutomation::GenerateCaption).to receive(:call).and_return(ok_result('a real caption'))

      results = described_class.call(dry_run: false, now: now)

      expect(results.map(&:outcome)).to eq([:refreshed])
      expect(post.reload.caption).to eq('a real caption')
      expect(post.caption_metadata).to include('model' => 'stub')
    end

    it 'leaves the post untouched when the captioner fails' do
      post = post_at(caption: 'Fresh look ✨', at: now + 1.hour)
      allow(PostAutomation::GenerateCaption).to receive(:call).and_return(bad_result)

      results = described_class.call(dry_run: false, now: now)

      expect(results.map(&:outcome)).to eq([:failed])
      expect(post.reload.caption).to eq('Fresh look ✨')
      expect(post.caption_metadata).to be_nil
    end

    it 'never raises out of a repair -- the placeholder is still publishable' do
      post = post_at(caption: 'Fresh look ✨', at: now + 1.hour)
      allow(PostAutomation::GenerateCaption).to receive(:call).and_raise(StandardError, 'boom')

      results = nil
      expect { results = described_class.call(dry_run: false, now: now) }.not_to raise_error
      expect(results.map(&:outcome)).to eq([:failed])
      expect(post.reload.caption).to eq('Fresh look ✨')
    end
  end
end
