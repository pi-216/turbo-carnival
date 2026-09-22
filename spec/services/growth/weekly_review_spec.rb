# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Growth::WeeklyReview do
  subject(:reviewer) { described_class.new(goal: goal) }

  let(:persona) { create(:persona) }
  let(:goal) do
    create(:growth_goal, persona: persona, start_followers: 151, target_followers: 1000,
                         posts_per_day: 2, max_posts_per_day: 3)
  end

  describe 'classify — declining (broken) verdict' do
    it 'concludes DECLINING when measured growth is negative (followers leaving)' do
      goal.snapshots.create!(followers: 150, taken_at: 1.day.ago)
      goal.snapshots.create!(followers: 148, taken_at: Time.current)

      expect(reviewer.send(:classify, -2, -1.0)).to eq('declining')
    end

    it 'concludes DECLINING on any net window loss, even with flat measured' do
      goal.snapshots.create!(followers: 150, taken_at: 2.days.ago)
      goal.snapshots.create!(followers: 151, taken_at: Time.current)

      expect(reviewer.send(:classify, -1, 0.0)).to eq('declining')
    end

    it 'keeps the growth-state verdicts unchanged (behind/flat/ahead)' do
      goal.snapshots.create!(followers: 150, taken_at: 2.days.ago)
      goal.snapshots.create!(followers: 151, taken_at: Time.current)

      expect(reviewer.send(:classify, 1, 0.5)).to eq('behind')  # ratio ~0.2 → behind
      expect(reviewer.send(:classify, 0, 0.0)).to eq('flat')

      # Ahead requires ratio >= 1.5 → measured ~3.5/day vs ~2.3 required.
      ahead_goal = create(:growth_goal, persona: persona, start_followers: 150, target_followers: 1000)
      ahead_goal.snapshots.create!(followers: 150, taken_at: 2.days.ago)
      ahead_goal.snapshots.create!(followers: 157, taken_at: Time.current)
      ahead_reviewer = described_class.new(goal: ahead_goal)

      expect(ahead_reviewer.send(:classify, 20, 5.0)).to eq('ahead')  # ratio ~1.5+ → ahead
    end
  end

  describe 'review with a DECLINING audit' do
    before do
      goal.snapshots.create!(followers: 150, taken_at: 1.day.ago)
      goal.snapshots.create!(followers: 148, taken_at: Time.current)
      # Evidence: >= 2 snapshots and >= 5 posted posts to pass the audit gate.
      allow(reviewer).to receive(:posted_posts).and_return([double] * 5)
      allow(reviewer).to receive(:gather_audit).and_return(
        followers_delta: -2, measured: -1.0, verdict: 'declining',
        pillars: [], hashtag_signal: {}, caption_signal: :none
      )
    end

    it 'records a declining review, HALTS persona evolution, and recommends diagnosis' do
      review = reviewer.review(apply: true, force: true)[:review]

      expect(review.verdict).to eq('declining')
      kinds = Array(review.applied_changes).map { |c| c.is_a?(Hash) ? c['kind'] : nil }
      expect(kinds).to contain_exactly('halt_persona_evolution')
      # No pillar reweight / hashtag / caption changes on a broken strategy.
      expect(kinds).not_to include('content_pillar', 'hashtag_strategy', 'caption_config')

      expect(review.persona_direction).to include('BROKEN')
      expect(review.recommendations.join(' ')).to include('HALT cadence increases')
      expect(review.recommendations.join(' ')).to include('Diagnose root cause')
    end
  end

  # The broaden lever was applied five weeks running with no effect, because
  # only the TIGHTEN direction was ever gated.
  describe 'the hashtag expand gate' do
    before do
      persona.hashtag_strategy = { max_tags: 30, brand_tags: [ 'test' ] }
      persona.save!
      goal.reviews.create!(
        reviewed_at: 1.week.ago, verdict: 'behind',
        applied_changes: [ {
          'kind' => 'hashtag_strategy',
          'from' => { 'max_tags' => 25, 'brand_tags' => [ 'test' ] },
          'to' => { 'max_tags' => 30, 'brand_tags' => [ 'test' ] },
          'reason' => 'low engagement — broaden tags'
        } ]
      )
    end

    it 'reverts a failed expansion all the way to the baseline' do
      allow(reviewer).to receive(:pillar_stats)
        .and_return([ { name: 'Fashion & Style', posts: 10, engagement: 0.4 } ])

      gates = reviewer.send(:evaluate_previous_gates)

      expect(gates[:reverted]).to include('expand-tags')
      expect(persona.reload.hashtag_strategy.max_tags).to eq(10)
      expect(gates[:actions].map { |a| a[:kind] }).to include('revert_hashtags')
    end

    it 'keeps an expansion that lifted engagement off the low bound it was justified by' do
      allow(reviewer).to receive(:pillar_stats)
        .and_return([ { name: 'Fashion & Style', posts: 10, engagement: 2.0 } ])

      gates = reviewer.send(:evaluate_previous_gates)

      expect(gates[:kept]).to include('expand-tags')
      expect(persona.reload.hashtag_strategy.max_tags).to eq(30)
    end
  end

  # The per-pillar read feeds the pre-registered GO/PIVOT/KILL criterion, and it
  # averaged the persona's LIFETIME posts (143 of them, back to 2025-12-16)
  # while this class documented a weekly read. A lifetime mean cannot show a
  # lever landing: it moves ~15% a week and every recent post scores 0.
  describe 'the per-pillar read window' do
    let(:pillar) { create(:content_pillar, persona: persona, name: 'Fashion & Style') }

    def posted(at:, engagement: 0.0)
      photo = ContentPillars::Photo.create!(persona: persona, path: "spec-#{SecureRandom.hex(4)}.png",
                                            content_pillar: pillar)
      Scheduling::Post.create!(persona: persona, photo: photo, caption: 'a real caption',
                               status: 'posted', posted_at: at, engagement_rate: engagement,
                               provider_post_id: "ig-#{SecureRandom.hex(6)}")
    end

    it 'averages only posts INSIDE the window, not the persona lifetime' do
      # Lifetime history: 20 posts at 5.0%, all older than the window.
      Array.new(20) { posted(at: 30.days.ago, engagement: 5.0) }
      # The week under review: 3 posts at 0.0%.
      Array.new(3) { posted(at: 2.days.ago, engagement: 0.0) }

      stats = reviewer.send(:pillar_stats).first

      expect(stats[:posts]).to eq(3)
      expect(stats[:engagement]).to eq(0.0)
      expect(stats[:window_days]).to eq(Growth::WeeklyReview::REVIEW_WINDOW_DAYS)
    end

    it 'reads an empty window as empty rather than falling back to history' do
      Array.new(20) { posted(at: 30.days.ago, engagement: 5.0) }

      expect(reviewer.send(:pillar_stats)).to eq([])
      # Account maturity still sees the lifetime history.
      expect(reviewer.send(:posted_posts).count).to eq(20)
    end
  end

  # A documented dry run used to write a review row AND run the gate evaluation,
  # which reverts content pillars / hashtags on a failed gate -- so DRY=1 mutated
  # the persona and left a row the NEXT review reads as `prev`.
  describe 'a dry run (apply: false)' do
    before do
      goal.snapshots.create!(followers: 150, taken_at: 2.days.ago)
      goal.snapshots.create!(followers: 151, taken_at: Time.current)
      allow(reviewer).to receive(:posted_posts).and_return([ double ] * 5)
      allow(reviewer).to receive(:gather_audit).and_return(
        followers_delta: 1, measured: 0.5, verdict: 'behind',
        pillars: [], hashtag_signal: {}, caption_signal: :none
      )
    end

    it 'writes no review row and runs no gate revert' do
      expect(reviewer).not_to receive(:evaluate_previous_gates)

      result = nil
      expect { result = reviewer.review(apply: false, force: true) }
        .not_to change { Growth::Review.count }

      expect(result[:review]).to be_a(Growth::Review)
      expect(result[:review]).not_to be_persisted
      expect(result[:verdict]).to eq('behind')
    end
  end
end