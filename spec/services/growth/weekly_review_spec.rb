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
end