# frozen_string_literal: true

require 'rails_helper'

# A post Instagram rejected used to lose its slot permanently: `failed` is terminal,
# the (photo_id, persona_id) index is unique (so no replacement row can exist), and
# nothing re-booked the row -- while the publisher still exited 0. These examples pin
# the two properties that make the retry safe on a LIVE account: only causes the
# failure reason itself classifies as transient are re-booked (a policy rejection is a
# decision, not a hiccup), and a row is retried at most once (idempotent, so re-running
# the repair can never book a second slot for one failure).
RSpec.describe Scheduling::FailedPostRetry do
  subject(:retry_service) { described_class.new }

  let(:persona) { create(:persona) }
  let!(:pillar) { create(:content_pillar, persona: persona, name: 'Fashion & Style', weight: 20) }
  let(:image_path) { Rails.root.join('tmp', "failed_post_retry_#{SecureRandom.hex(6)}.png").to_s }
  let(:photo) do
    ContentPillars::Photo.create!(persona: persona, path: image_path, content_pillar: pillar)
  end

  # The real reason string the publisher persists (post 333, 2026-09-20).
  let(:transient_reason) do
    'instagram: 400 code 9007 (Media ID is not available -- the media is not ready for publishing)'
  end
  let(:policy_reason) { 'instagram: 400 code 100 (The media upload was rejected for policy reasons)' }

  before do
    FileUtils.mkdir_p(File.dirname(image_path))
    File.binwrite(image_path, 'not-really-a-png')
  end

  after { FileUtils.rm_f(image_path) }

  def failed_post(reason:, at: 5.minutes.ago, **attrs)
    Scheduling::Post.create!(
      {
        persona: persona,
        photo: photo,
        caption: 'A caption that was already paid for',
        hashtags: %w[#keep #these],
        status: 'failed',
        scheduled_at: 1.hour.ago,
        optimal_time_calculated: 1.hour.ago,
        strategy_name: 'turbo-one-step',
        failure_reason: reason
      }.merge(attrs)
    ).tap { |post| post.update_column(:updated_at, at) }
  end

  describe '#call' do
    it 're-books a transiently rejected post onto a future slot, keeping its content' do
      post = failed_post(reason: transient_reason)

      result = retry_service.call(limit: 3)

      expect(result.requeued).to eq(1)
      expect(result.post_ids).to eq([ post.id ])

      post.reload
      expect(post.status).to eq('scheduled')
      expect(post.scheduled_at).to be > Time.current
      expect(post.scheduled_at).to eq(post.optimal_time_calculated)
      expect(post.failure_reason).to start_with('retry#1 ')
      expect(post.failure_reason).to include('9007')
      expect(post.photo_id).to eq(photo.id)
      expect(post.caption).to eq('A caption that was already paid for')
      expect(post.hashtags).to eq(%w[#keep #these])
      expect(post.strategy_name).to eq('turbo-one-step')
    end

    it 'never re-books a policy rejection -- that is a decision, not a hiccup' do
      post = failed_post(reason: policy_reason)

      result = retry_service.call(limit: 3)

      expect(result.requeued).to eq(0)
      expect(result.skipped).to eq(1)
      post.reload
      expect(post.status).to eq('failed')
      expect(post.failure_reason).to eq(policy_reason)
    end

    it 'is idempotent: an already retried row is skipped' do
      post = failed_post(reason: "retry#1 re-booked 2026-09-21T09:00:00Z | #{transient_reason}")

      result = retry_service.call(limit: 3)

      expect(result.requeued).to eq(0)
      expect(result.skipped).to eq(1)
      expect(post.reload.status).to eq('failed')
    end

    it 're-booked rows are not re-booked again on a later run' do
      failed_post(reason: transient_reason)
      expect(retry_service.call(limit: 3).requeued).to eq(1)

      second = retry_service.call(limit: 3)

      expect(second.examined).to eq(0)
      expect(second.requeued).to eq(0)
    end

    it 'ignores failures older than the window' do
      failed_post(reason: transient_reason, at: 3.days.ago)

      result = retry_service.call(limit: 3)

      expect(result.examined).to eq(0)
      expect(result.requeued).to eq(0)
    end

    it 'skips a row whose photo file is gone (Instagram would only reject it again)' do
      post = failed_post(reason: transient_reason)
      FileUtils.rm_f(image_path)

      result = retry_service.call(limit: 3)

      expect(result.requeued).to eq(0)
      expect(result.skipped).to eq(1)
      expect(result.reasons.first).to include('photo file is gone')
      expect(post.reload.status).to eq('failed')
    end

    it 'skips a row with no stored reason -- the cause cannot be classified' do
      post = failed_post(reason: '')

      result = retry_service.call(limit: 3)

      expect(result.requeued).to eq(0)
      expect(result.reasons.first).to include('no failure reason')
      expect(post.reload.status).to eq('failed')
    end

    it 'treats a network timeout as transient' do
      failed_post(reason: 'instagram: Request failed: execution expired (timeout)')

      expect(retry_service.call(limit: 3).requeued).to eq(1)
    end

    it 'bounds the batch by limit' do
      other_photo = ContentPillars::Photo.create!(
        persona: persona, path: "#{image_path}.2", content_pillar: pillar
      )
      File.binwrite(other_photo.path, 'not-really-a-png')
      first = failed_post(reason: transient_reason)
      second = failed_post(reason: transient_reason, photo: other_photo)

      result = retry_service.call(limit: 1)

      expect(result.requeued).to eq(1)
      expect([ first.reload.status, second.reload.status ].count('scheduled')).to eq(1)
      FileUtils.rm_f(other_photo.path)
    end

    it 'writes nothing in dry-run mode, while still reporting the eligible row' do
      post = failed_post(reason: transient_reason)

      result = described_class.new(dry_run: true).call(limit: 3)

      expect(result.requeued).to eq(1)
      post.reload
      expect(post.status).to eq('failed')
      expect(post.failure_reason).to eq(transient_reason)
    end
  end
end
