# frozen_string_literal: true

require 'rails_helper'

# The pre-registered GO/PIVOT/KILL gate was prose on the ops board, and the
# cohort-validity rule it needs (whether the engagement leg is a measurement at
# all) is the part that gets re-derived differently by every reader. These
# examples pin the mapping AND the rule that an unobservable cohort can never
# produce a verdict about the intervention.
RSpec.describe Growth::GateRead do
  subject(:read) { described_class.new(goal: goal).call }

  let(:persona) { create(:persona) }
  let(:goal) do
    create(:growth_goal, persona: persona, start_followers: 151, target_followers: 1000,
                         posts_per_day: 2, max_posts_per_day: 3)
  end
  let(:pillar) { create(:content_pillar, persona: persona, name: 'Fashion & Style') }

  # A published post whose render was imported at `rendered_at` and which carries
  # (or lacks) collected insights.
  def posted(at:, engagement: 0.0, rendered_at: Time.current, insights: true)
    photo = ContentPillars::Photo.create!(persona: persona, path: "spec-#{SecureRandom.hex(4)}.png",
                                          content_pillar: pillar, created_at: rendered_at)
    Scheduling::Post.create!(persona: persona, photo: photo, caption: 'a real caption',
                             status: 'posted', posted_at: at, engagement_rate: engagement,
                             provider_post_id: "ig-#{SecureRandom.hex(6)}",
                             insights_updated_at: insights ? Time.current : nil)
  end

  # Cohort-valid fixture: MIN_COHORT_POSTS post-intervention posts with insights.
  def valid_cohort(engagement: 0.0)
    Array.new(described_class::MIN_COHORT_POSTS) { posted(at: 1.day.ago, engagement: engagement) }
  end

  before { allow(goal).to receive(:latest_followers).and_return(158) }

  it 'EXTENDS when the cohort cannot testify about the intervention' do
    # Plenty of posts in the window, but every one of them was RENDERED before the
    # 09-21 levers landed -- the exact shape that would otherwise read as "the
    # lever failed" when the lever has no published cohort at all.
    Array.new(10) { posted(at: 1.day.ago, rendered_at: described_class::INTERVENTION_AT - 2.days) }

    expect(read[:verdict]).to eq(:extend)
    expect(read[:engagement][:cohort]).to eq(0)
    expect(read[:engagement][:cohort_valid]).to be(false)
  end

  it 'does not count a post-intervention render without collected insights' do
    valid_cohort
    Array.new(4) { posted(at: 1.day.ago, insights: false) }

    expect(read[:engagement][:cohort]).to eq(described_class::MIN_COHORT_POSTS)
  end

  it 'does not count a post-intervention render that has not published yet' do
    valid_cohort
    Array.new(4) { posted(at: 30.days.ago) } # published outside the review window

    expect(read[:engagement][:cohort]).to eq(described_class::MIN_COHORT_POSTS)
  end

  it 'FIRES the gate when both legs fail on a valid cohort' do
    valid_cohort(engagement: 0.0)

    expect(read[:verdict]).to eq(:gate_fires)
    expect(read[:followers][:pass]).to be(false)
    expect(read[:engagement][:pass]).to be(false)
  end

  it 'GOes only when BOTH legs pass' do
    allow(goal).to receive(:latest_followers).and_return(180)
    valid_cohort(engagement: 3.5)

    expect(read[:verdict]).to eq(:go)
  end

  it 'CONTINUEs when exactly one leg fails (the locked conjunction has not fired)' do
    allow(goal).to receive(:latest_followers).and_return(180)
    valid_cohort(engagement: 0.0)

    expect(read[:verdict]).to eq(:continue)
  end

  it 'treats the floor as EXCLUSIVE -- a pillar exactly at 3.0% does not pass' do
    allow(goal).to receive(:latest_followers).and_return(180)
    valid_cohort(engagement: described_class::PILLAR_ENGAGEMENT_FLOOR)

    expect(read[:engagement][:pass]).to be(false)
    expect(read[:verdict]).to eq(:continue)
  end

  it 'reads the same window the weekly review judges on' do
    valid_cohort(engagement: 1.0)

    expect(read[:engagement][:window_days]).to eq(Growth::WeeklyReview::REVIEW_WINDOW_DAYS)
    expect(read[:engagement][:window_posts]).to eq(described_class::MIN_COHORT_POSTS)
  end

  it 'writes nothing' do
    valid_cohort

    expect { read }.not_to change { Growth::Review.count }
  end
end
