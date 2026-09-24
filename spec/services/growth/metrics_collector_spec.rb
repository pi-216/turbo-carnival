# frozen_string_literal: true

require 'rails_helper'

# The follower count is the number every trajectory read is built from, and the
# reach attribution added beside it (2026-09-24) is what tells discovery from an
# audience that only ever sees its own posts. The rule this pins: an UNMEASURED
# attribution must stay NULL and must never cost the follower snapshot -- a
# fabricated 0 would read as a measured "no discovery", which is exactly the
# verdict the pre-registered gate's distribution pivot turns on.
RSpec.describe Growth::MetricsCollector do
  subject(:collector) { described_class.new(goal: goal) }

  let(:persona) { create(:persona) }
  let(:goal) { create(:growth_goal, persona: persona) }

  def stub_client(followers: 157, attribution: { follower_reach: 6, non_follower_reach: 0,
                                                 reach_total: 6, profile_views: 0 },
                  raise_attribution: false)
    instance = instance_double(Instagram::Client)
    allow(instance).to receive(:followers_count).and_return(followers)
    if raise_attribution
      allow(instance).to receive(:reach_attribution)
        .and_raise(Instagram::Client::Error, 'insights unavailable')
    else
      allow(instance).to receive(:reach_attribution).and_return(attribution)
    end
    allow(Instagram::Client).to receive(:new).and_return(instance)
  end

  it 'records the follower count together with the reach attribution' do
    stub_client

    snap = collector.collect

    expect(snap.followers).to eq(157)
    expect(snap.follower_reach).to eq(6)
    expect(snap.non_follower_reach).to eq(0)
    expect(snap.reach_total).to eq(6)
    expect(snap.profile_views).to eq(0)
    expect(snap.discovery?).to be(false)
  end

  it 'marks a measured non-follower reach as discovery' do
    stub_client(attribution: { follower_reach: 3, non_follower_reach: 9, reach_total: 12 })

    expect(collector.collect.discovery?).to be(true)
  end

  it 'keeps the follower snapshot when the attribution call fails, and leaves the columns UNKNOWN' do
    stub_client(raise_attribution: true)

    snap = collector.collect

    expect(snap.followers).to eq(157)
    expect(snap.non_follower_reach).to be_nil
    expect(snap.follower_reach).to be_nil
    expect(snap.profile_views).to be_nil
    expect(snap.discovery?).to be(false)
  end

  it 'does not turn a dimension the API omitted into a zero' do
    stub_client(attribution: { reach_total: 6 })

    snap = collector.collect

    expect(snap.reach_total).to eq(6)
    expect(snap.non_follower_reach).to be_nil
  end

  it 'still records a decision and returns nil when the follower call itself fails' do
    instance = instance_double(Instagram::Client)
    allow(instance).to receive(:followers_count).and_raise(Instagram::Client::Error, 'token expired')
    allow(Instagram::Client).to receive(:new).and_return(instance)

    expect(collector.collect).to be_nil
    expect(goal.snapshots.count).to eq(0)
    expect(Growth::Decision.last.action).to eq('skip_data')
  end
end