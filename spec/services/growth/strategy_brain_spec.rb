# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Growth::StrategyBrain do
  subject(:brain) { described_class.new(goal: goal) }

  let(:persona) { create(:persona) }

  # Declining goal: 151 → 149 over 2 days = -1.0/day measured vs ~2.4/day
  # required → traj_ratio ≈ -0.41 (negative = followers leaving).
  let(:goal) do
    create(:growth_goal, persona: persona, start_followers: 151, target_followers: 1000,
                         posts_per_day: 2, max_posts_per_day: 3,
                         review_interval_days: 7, last_reviewed_at: 10.days.ago)
  end

  describe 'negative growth (followers leaving)' do
    before do
      goal.snapshots.create!(followers: 151, taken_at: 3.days.ago)
      goal.snapshots.create!(followers: 149, taken_at: 1.day.ago)
    end

    it 'concludes NEGATIVE GROWTH BREAK — not escalate — and retracts cadence' do
      result = brain.review

      expect(result[:view]).to eq('negative_growth_break')
      expect(goal.reload.posts_per_day).to eq(1) # retracted 2 → 1, never raised

      decision = Growth::Decision.order(decided_at: :desc).first
      expect(decision.action).to eq('negative_growth_break')
      expect(decision.reason).to include('followers are LEAVING')
      expect(decision.reason).to include('strategy broken, not behind')
      expect(decision.to_values['posts_per_day']).to eq(1)
    end

    it 'fires immediately even inside the review interval (anomaly, never waits)' do
      goal.update!(last_reviewed_at: Time.current) # just reviewed — normally not due

      result = brain.review

      expect(result[:view]).to eq('negative_growth_break')
    end

    it 'concludes ONCE per decline episode — skips hourly ticks, re-confirms after the interval' do
      brain.review
      expect(goal.reload.posts_per_day).to eq(1)

      # Straight re-review (next hourly tick): conclusion already recorded → skip.
      result = described_class.new(goal: goal).review
      expect(result[:view]).to eq('skip')

      # Interval elapses while decline continues → re-concludes (no new blob).
      decision = Growth::Decision.order(decided_at: :desc).first
      decision.update!(decided_at: (goal.review_interval_days + 1).days.ago)
      result = described_class.new(goal: goal.reload).review
      expect(result[:view]).to eq('negative_growth_break')
    end
  end

  describe 'behind but still growing' do
    # 151 → 153 over 4 days = +0.5/day vs ~2.4 required → ratio ≈ 0.21 (behind, positive).
    let(:goal) do
      create(:growth_goal, persona: persona, start_followers: 151, target_followers: 1000,
                           posts_per_day: 1, max_posts_per_day: 3,
                           review_interval_days: 7, last_reviewed_at: 10.days.ago)
    end

    before do
      goal.snapshots.create!(followers: 151, taken_at: 5.days.ago)
      goal.snapshots.create!(followers: 153, taken_at: 1.day.ago)
    end

    it 'still escalates cadence (slow growth ≠ follower loss)' do
      result = brain.review

      expect(result[:view]).to eq('escalate_cadence')
      expect(goal.reload.posts_per_day).to eq(2)
      expect(Growth::Decision.order(decided_at: :desc).first.action).to eq('escalate_cadence')
    end

    it 'skips when the interval has not elapsed (no anomaly)' do
      goal.update!(last_reviewed_at: Time.current)

      result = brain.review

      expect(result[:view]).to eq('skip')
    end

    # Two different clocks both read as "the next review": this one is the BRAIN's
    # own throttle (goal.last_reviewed_at, touched on every due evaluation) and the
    # other is the weekly review's cadence (growth_reviews.reviewed_at). Measured
    # 2026-09-24 they disagreed by 2 days, and the hourly report's key invited a
    # reader to take the brain's for the pre-registered read's date.
    it 'reports its own throttle under a name that cannot be read as the weekly review' do
      goal.update!(last_reviewed_at: Time.current)

      result = brain.review

      expect(result).to have_key(:next_strategy_review_at)
      expect(result).not_to have_key(:next_review_at)
      expect(result[:next_strategy_review_at])
        .to be_within(1.minute).of(goal.reload.last_reviewed_at + goal.review_interval_days.days)
    end
  end

  describe 'escalation exhaustion (live knobs only)' do
    # At max cadence with the ratio still below ESCALATE_THRESHOLD the ladder has
    # nothing live left to pull, so the exhaustion conclusion must be PERSISTED
    # (the change's "escalation reaching its ceiling SHALL NOT be a silent
    # no-op"). `hashtag_count` is deliberately NOT a rung: nothing in the
    # production path reads it -- post tags come from ContentStrategy::HashtagEngine
    # and Personas::HashtagStrategy#max_tags, which enforce_tag_baseline pins to
    # TAG_BASELINE because the 10 -> 30 broaden ramp was disproven -- so ramping it
    # recorded an adjustment that changed nothing and delayed this conclusion.
    let(:goal) do
      create(:growth_goal, persona: persona, start_followers: 151, target_followers: 1000,
                           posts_per_day: 3, max_posts_per_day: 3, hashtag_count: 20,
                           review_interval_days: 7, last_reviewed_at: 10.days.ago)
    end

    before do
      goal.snapshots.create!(followers: 151, taken_at: 5.days.ago)
      goal.snapshots.create!(followers: 153, taken_at: 1.day.ago)
    end

    it 'persists strategy_exhausted naming the live knob and leaves the inert field alone' do
      result = brain.review

      expect(result[:view]).to eq('strategy_exhausted')
      expect(goal.reload.posts_per_day).to eq(3)  # at max, never raised past it
      expect(goal.hashtag_count).to eq(20)        # inert knob untouched

      decision = Growth::Decision.order(decided_at: :desc).first
      expect(decision.action).to eq('strategy_exhausted')
      expect(decision.reason).to include('posts_per_day=3/3')
      expect(decision.reason).to include('no volume knob left')
    end
  end
end
