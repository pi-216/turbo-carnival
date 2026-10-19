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
                                                 reach_total: 6, profile_views: 0,
                                                 accounts_engaged: 0 },
                  media_count: 224, raise_attribution: false, raise_media_count: false)
    instance = instance_double(Instagram::Client)
    allow(instance).to receive(:followers_count).and_return(followers)
    if raise_attribution
      allow(instance).to receive(:reach_attribution)
        .and_raise(Instagram::Client::Error, 'insights unavailable')
    else
      allow(instance).to receive(:reach_attribution).and_return(attribution)
    end
    if raise_media_count
      allow(instance).to receive(:media_count).and_raise(Instagram::Client::Error, 'account unavailable')
    else
      allow(instance).to receive(:media_count).and_return(media_count)
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
    expect(snap.accounts_engaged).to eq(0)
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
    expect(snap.accounts_engaged).to be_nil
    expect(snap.discovery?).to be(false)
  end

  # The platform's own daily engagement counter is the ONE independent read of
  # the zero the ops board tracks, so an unanswered call must land as NULL and
  # never as 0 -- a 0 would be published as "the platform agrees nobody engaged".
  it 'leaves the platform engagement counter UNKNOWN (nil) when the API did not answer it' do
    stub_client(attribution: { reach_total: 6, accounts_engaged: nil })

    snap = collector.collect

    expect(snap.followers).to eq(157)
    expect(snap.reach_total).to eq(6)
    expect(snap.accounts_engaged).to be_nil
  end

  it 'does not turn a dimension the API omitted into a zero' do
    stub_client(attribution: { reach_total: 6 })

    snap = collector.collect

    expect(snap.reach_total).to eq(6)
    expect(snap.non_follower_reach).to be_nil
  end

  # The account's own media inventory is the only number that can distinguish a
  # platform-side REMOVAL from our bookkeeping: provider_post_id is written once
  # at publish and never re-read, so a taken-down post keeps counting as posted
  # everywhere. Publishing can only INCREASE media_count, which is why the column
  # has to be measured on every snapshot rather than inferred.
  it 'records the account media inventory beside the follower count' do
    stub_client(media_count: 224)

    expect(collector.collect.media_count).to eq(224)
  end

  it 'leaves the media inventory UNKNOWN (nil) when the account call fails, without losing the snapshot' do
    stub_client(raise_media_count: true)

    snap = collector.collect

    expect(snap.followers).to eq(157)
    expect(snap.media_count).to be_nil
  end

  it 'keeps the follower count when the API answers without a media_count field' do
    stub_client(media_count: nil)

    snap = collector.collect

    expect(snap.followers).to eq(157)
    expect(snap.media_count).to be_nil
  end

  it 'still records a decision and returns nil when the follower call itself fails' do
    instance = instance_double(Instagram::Client)
    allow(instance).to receive(:followers_count).and_raise(Instagram::Client::Error, 'token expired')
    allow(Instagram::Client).to receive(:new).and_return(instance)

    expect(collector.collect).to be_nil
    expect(goal.snapshots.count).to eq(0)
    expect(Growth::Decision.last.action).to eq('skip_data')
  end

  # PRD 0006 R7 · ticket #77: the snapshot is the charter's measurement, and this is the tick
  # that has to emit it -- a stored number nobody alerts on is untracked. Asserted through the
  # real SDK transport rather than a spy on CharterTelemetry: a spy would prove only that a
  # call was made, not that a metric reaches the wire.
  context 'with the Sentry pillar live' do
    include_context 'with sentry telemetry'

    it 'emits the charter gauges from the snapshot it just recorded' do
      goal.update!(target_followers: 1000, start_followers: 0, deadline: Date.current + 100.days)
      stub_client(followers: 160)

      collector.collect

      followers = emitted_metrics.find { |m| m[:name] == 'growth.followers' }
      pace = emitted_metrics.find { |m| m[:name] == 'growth.required_per_day' }

      expect(followers[:type]).to eq(:gauge)
      expect(followers[:value]).to eq(160)
      # (1000 - 160) followers still to find, over the 100 days the deadline leaves.
      expect(pace[:type]).to eq(:gauge)
      expect(pace[:value]).to be_within(0.001).of(8.4)
      # Inventory rides the same tick -- the collector is the only hourly job the live
      # harness runs, so a series missing here would have no scheduled home at all.
      expect(emitted_metrics.map { |m| m[:name] }).to include('inventory.personas', 'inventory.assets')
    end
  end
end
