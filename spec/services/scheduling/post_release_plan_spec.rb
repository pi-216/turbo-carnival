# frozen_string_literal: true

require 'rails_helper'

# The publisher released EVERY due post in one pass, so two slots less than an
# hour apart left the account as a burst (measured 2026-09-19: four posts inside
# 90 min; the pre-fix queue still holds pairs 14 min apart through 09-25). These
# examples pin the two properties the pacing must have to be safe on the one path
# that must never stall: exactly one post is released per run, and everything
# else is DEFERRED -- never dropped, never failed, still selected next tick.
RSpec.describe Scheduling::PostReleasePlan do
  def posts(n)
    Array.new(n) { |i| { id: i + 1, slot: Time.zone.local(2026, 9, 20, 15, 0) + i.minutes } }
  end

  it 'releases the single due post and defers nothing' do
    plan = described_class.call(posts(1))

    expect(plan.released.map { |p| p[:id] }).to eq([1])
    expect(plan.deferred).to be_empty
  end

  it 'releases only the earliest post when several are due at once' do
    plan = described_class.call(posts(4))

    expect(plan.released.map { |p| p[:id] }).to eq([1])
    expect(plan.deferred.map { |p| p[:id] }).to eq([2, 3, 4])
  end

  it 'accounts for every due post -- deferral never drops one' do
    due = posts(5)
    plan = described_class.call(due)

    expect(plan.released + plan.deferred).to match_array(due)
    expect(plan.released.size + plan.deferred.size).to eq(due.size)
  end

  it 'releases nothing when nothing is due' do
    plan = described_class.call([])

    expect(plan.released).to be_empty
    expect(plan.deferred).to be_empty
  end

  it 'takes the per-run cap from the caller' do
    plan = described_class.call(posts(4), max_per_run: 2)

    expect(plan.released.map { |p| p[:id] }).to eq([1, 2])
    expect(plan.deferred.map { |p| p[:id] }).to eq([3, 4])
  end
end
