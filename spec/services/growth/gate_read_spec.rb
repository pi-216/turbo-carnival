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
  # A pillar whose posts all predate the levers -- the set that must NOT be able
  # to decide the engagement leg.
  let(:pre_pillar) { create(:content_pillar, persona: persona, name: 'Travel & Adventure') }

  # A published post whose render was imported at `rendered_at` and which carries
  # (or lacks) collected insights.
  def posted(at:, engagement: 0.0, rendered_at: Time.current, insights: true, pillar: nil,
             unavailable: false)
    photo = ContentPillars::Photo.create!(persona: persona, path: "spec-#{SecureRandom.hex(4)}.png",
                                          content_pillar: pillar || self.pillar,
                                          created_at: rendered_at)
    Scheduling::Post.create!(persona: persona, photo: photo, caption: 'a real caption',
                             status: 'posted', posted_at: at, engagement_rate: engagement,
                             provider_post_id: "ig-#{SecureRandom.hex(6)}",
                             insights_updated_at: insights ? Time.current : nil,
                             insights_unavailable_at: unavailable ? Time.current : nil)
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

  # The class's own rule -- "a post RENDERED before this instant cannot carry any
  # lever's effect, so it cannot vote on the gate" -- is a property of the SET the
  # engagement leg reads. The window still holds pre-intervention renders while the
  # pool fills (publication lags the render by the queue depth), and the pillar
  # table the leg used to average over was the UNFILTERED window, so a pillar whose
  # every post predates the levers could be the gate's "top pillar" and pass the
  # leg on content the intervention never touched.
  it 'does not let a pre-intervention render vote on the engagement leg' do
    valid_cohort(engagement: 0.0)
    Array.new(3) do
      posted(at: 1.day.ago, engagement: 9.0, pillar: pre_pillar,
             rendered_at: described_class::INTERVENTION_AT - 2.days)
    end

    expect(read[:engagement][:max]).to eq(0.0)
    expect(read[:engagement][:pass]).to be(false)
    expect(read[:verdict]).to eq(:gate_fires)
    # The unfiltered window DOES see it: reported beside the leg, never silent.
    expect(read[:engagement][:window_max]).to eq(9.0)
    expect(read[:engagement][:window_max_pillar]).to eq('Travel & Adventure')
  end

  it 'reports the leg as measured on the cohort, naming the set it read' do
    valid_cohort(engagement: 1.0)
    posted(at: 1.day.ago, engagement: 9.0, pillar: pre_pillar,
           rendered_at: described_class::INTERVENTION_AT - 2.days)

    expect(read[:engagement][:measured_on]).to eq('cohort')
    expect(read[:pillars].map { |p| p[:name] }).to eq([ 'Fashion & Style' ])
    expect(read[:engagement][:window_max_pillar]).to eq('Travel & Adventure')
  end

  it 'writes nothing' do
    valid_cohort

    expect { read }.not_to change { Growth::Review.count }
  end

  # Instagram has removed 36 of the 150 posts this app published, and the erasure
  # is invisible to `gate=` in BOTH directions -- so the read has to name it beside
  # the cohort it judges. Direction 1: erased AFTER collection, so the post still
  # testifies, with the zeros it earned post-erasure.
  it 'names cohort posts the platform has REMOVED (they vote with post-erasure zeros)' do
    valid_cohort(engagement: 0.0)
    posted(at: 1.day.ago, unavailable: true)

    expect(read[:removal][:in_cohort]).to eq(1)
    expect(read[:removal][:gone_uncollected]).to eq(0)
    expect(read[:reason]).to include('REMOVED')
  end

  # Direction 2, the silent one: erased BEFORE its first collection, so it can
  # never enter the cohort. A wave of these shrinks the cohort toward :extend,
  # which reads as "not enough data yet" when the platform deleted the evidence.
  it 'names post-intervention posts erased BEFORE collection (excluded, not absent)' do
    valid_cohort(engagement: 1.0)
    Array.new(3) { posted(at: 1.day.ago, insights: false, unavailable: true) }

    expect(read[:removal][:gone_uncollected]).to eq(3)
    expect(read[:removal][:in_cohort]).to eq(0)
    expect(read[:engagement][:cohort]).to eq(described_class::MIN_COHORT_POSTS)
    expect(read[:reason]).to include('ERASURE')
  end

  it 'adds no confound clause when nothing this leg reads is gone' do
    valid_cohort(engagement: 1.0)

    expect(read[:removal]).to eq(rendered: described_class::MIN_COHORT_POSTS,
                                in_cohort: 0, gone_uncollected: 0)
    expect(read[:reason]).not_to include('CONFOUND')
  end

  # The gate's own pivot candidate is distribution/reach, and the platform's
  # follow_type breakdown is the only counter that separates "our followers see
  # every post" from "strangers find us" -- the same class of confound as the
  # erasure, from the other direction: without it a failing engagement leg reads
  # as a content result when it may be a distribution ceiling.
  it 'carries the account-level discovery split, and calls a measured zero a ceiling' do
    valid_cohort(engagement: 0.0)
    goal.snapshots.create!(followers: 158, taken_at: 1.hour.ago, follower_reach: 6,
                           non_follower_reach: 0, reach_total: 6, profile_views: 0)

    expect(read[:discovery][:measured]).to be(true)
    expect(read[:discovery][:non_follower_reach]).to eq(0)
    expect(read[:reason]).to include('DISTRIBUTION ceiling')
  end

  # Measured 2026-09-25: the split moved off a 33-snapshot hard zero to
  # non-follower=1 of 7. The pivot's own metric is `> 0`, so it is satisfied
  # BEFORE the arm exists -- and a read that does not say so invites reading the
  # arm's own `> 0` result as the arm working.
  it 'says so when the pivot metric is already non-zero before the arm' do
    valid_cohort(engagement: 0.0)
    goal.snapshots.create!(followers: 158, taken_at: 1.hour.ago, follower_reach: 6,
                           non_follower_reach: 1, reach_total: 7, profile_views: 0)

    expect(read[:discovery][:non_follower_reach]).to eq(1)
    expect(read[:reason]).to include('ALREADY satisfied')
  end

  # NULL is "never measured", deliberately not a zero: a broken call must not be
  # able to read as "no discovery at all".
  it 'reports an UNMEASURED split as unmeasured, never as a zero' do
    valid_cohort(engagement: 1.0)
    goal.snapshots.create!(followers: 158, taken_at: 1.hour.ago)

    expect(read[:discovery][:measured]).to be(false)
    expect(read[:discovery][:non_follower_reach]).to be_nil
    expect(read[:reason]).not_to include('DISCOVERY')
  end
end
