# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Growth::LibraryFallback do
  subject(:fallback) { described_class.new(goal: goal, captioner: captioner) }

  let(:persona) { create(:persona) }
  let!(:pillar) { create(:content_pillar, persona: persona, name: 'Fashion & Style', weight: 20) }
  let(:goal) { create(:growth_goal, persona: persona, posts_per_day: 3, max_posts_per_day: 3) }
  let(:captioner) { double('captioner') }

  let(:nsfw_ok) do
    Growth::NsfwGate::Result.new(label: 'normal', nsfw_score: 0.01, flagged: false)
  end
  let(:realism_ok) do
    Growth::RealismGate::Result.new(safe: true, aesthetic_score: 5.2, sharpness: 80.0)
  end

  # One servable, unposted library photo per call.
  def library_photo!
    path = Rails.root.join('tmp', "library_spec_#{SecureRandom.hex(6)}.png").to_s
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, 'not-really-a-png')
    @paths << path
    ContentPillars::Photo.create!(persona: persona, content_pillar: pillar, path: path,
                                  synthetic: true, provenance: { 'source' => 'spec' })
  end

  # A queued post whose clock sits `hours` out -- this IS the publish runway.
  def queued_post!(hours:)
    other = library_photo!
    Scheduling::Post.create!(persona: persona, photo: other, caption: 'queued',
                             status: 'scheduled', scheduled_at: hours.hours.from_now,
                             optimal_time_calculated: hours.hours.from_now,
                             strategy_name: 'spec-runway')
  end

  before do
    @paths = []
    allow(Growth::NsfwGate).to receive(:new).and_return(double('nsfw', call: nsfw_ok))
    allow(Growth::RealismGate).to receive(:new).and_return(double('realism', call: realism_ok))
    allow(captioner).to receive(:call).and_return(double(success?: true, caption: 'Library caption'))
    allow(ContentStrategy::HashtagEngine).to receive(:generate).and_return(%w[#lib])
  end

  after { @paths.each { |p| FileUtils.rm_f(p) } }

  describe 'the runway trigger' do
    it 'leaves the library alone while the queue has runway' do
      queued_post!(hours: 240)
      library_photo!

      result = fallback.call

      expect(result.triggered).to be(false)
      expect(result.created).to eq(0)
      expect(result.runway_hours).to be_within(1.0).of(240.0)
      expect(Scheduling::Post.where(strategy_name: 'library-fallback')).to be_empty
    end

    it 'spends library photos once the runway is inside the trigger' do
      queued_post!(hours: 24)
      library_photo!

      result = fallback.call

      expect(result.triggered).to be(true)
      expect(result.created).to eq(1)

      post = Scheduling::Post.find(result.post_ids.first)
      expect(post.status).to eq('scheduled')
      expect(post.strategy_name).to eq('library-fallback')
      expect(post.scheduled_at).to be > Time.current
      expect(post.caption).to eq('Library caption')
      expect(post.caption_metadata['library_fallback']).to be_present
    end

    it 'caps the spend at MAX_PER_CALL however short the runway is' do
      # No queued post at all: runway 0, so the top-up budget would be 12 posts.
      4.times { library_photo! }

      result = fallback.call

      expect(result.budget).to eq(described_class::MAX_PER_CALL)
      expect(result.created).to eq(described_class::MAX_PER_CALL)
    end

    it 'ignores the trigger when forced (manual invocation)' do
      queued_post!(hours: 240)
      library_photo!

      result = fallback.call(force: true)

      expect(result.triggered).to be(true)
      expect(result.created).to eq(1)
    end
  end

  describe 'the gates' do
    # PRD 0007 A1: the reserve is where "keep flagged assets for re-valuation" has to
    # be visible, so the score is recorded ON THE ASSET ROW -- and the spend proceeds.
    # (Realism still vetoes; see the next example.)
    it 'spends a flagged library photo and records the score on the asset instead of vetoing' do
      allow(Growth::NsfwGate).to receive(:new)
        .and_return(double('nsfw', call: Growth::NsfwGate::Result.new(nsfw_score: 0.9992, label: 'nsfw',
                                                                      flagged: true)))
      queued_post!(hours: 24)
      flagged = library_photo!

      result = fallback.call

      expect(result.created).to eq(1)
      expect(result.rejected).to eq(0)
      flagged.reload
      expect(flagged.nsfw_score).to be_within(0.0001).of(0.9992)
      expect(flagged.nsfw_flagged).to be(true)
      expect(Scheduling::Post.exists?(photo_id: flagged.id)).to be(true)
    end

    it 'never schedules a library photo the realism gate rejects' do
      allow(Growth::RealismGate).to receive(:new)
        .and_return(double('realism', call: Growth::RealismGate::Result.new(safe: false,
                                                                           reason: 'aesthetic 3.1')))
      queued_post!(hours: 24)
      rejected = library_photo!

      result = fallback.call

      expect(result.created).to eq(0)
      expect(result.rejected).to eq(1)
      expect(Scheduling::Post.exists?(photo_id: rejected.id)).to be(false)
    end
  end

  describe 'idempotency' do
    it 'cannot double-post: a photo a post already references is not a candidate' do
      queued_post!(hours: 24)
      photo = library_photo!
      fallback.call # spends the photo

      result = fallback.call

      expect(result.created).to eq(0)
      expect(Scheduling::Post.where(photo_id: photo.id).count).to eq(1)
    end
  end
end
