# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Growth::Authority do
  subject(:authority) { described_class.new(goal: goal) }

  let(:persona) { create(:persona) }
  let(:goal) do
    create(:growth_goal, persona: persona, start_followers: 151, target_followers: 1000,
                         review_interval_days: 7)
  end

  describe '#resource_blocked?' do
    it 'true when render-blockage decisions cover >= 60% of the window' do
      # 168-hour window; 120 block hour-rows -> 0.71 density.
      120.times do
        goal.decisions.create!(action: 'comfyui_unclaimed', decided_at: 3.days.ago)
      end

      expect(authority.resource_blocked?).to be true
    end

    it 'false when blockage density is below threshold' do
      goal.decisions.create!(action: 'comfyui_unclaimed', decided_at: 1.hour.ago)

      expect(authority.resource_blocked?).to be false
    end
  end

  describe '#goal_unattainable?' do
    it 'true when ratio < KILL and behind has persisted for KILL_AFTER_REVIEWS' do
      allow(goal).to receive(:traj_ratio).and_return(0.1)
      4.times do |i|
        goal.reviews.create!(reviewed_at: (i + 1).weeks.ago, verdict: 'behind')
      end

      expect(authority.goal_unattainable?).to be true
    end

    it 'false when ratio is above the kill threshold' do
      allow(goal).to receive(:traj_ratio).and_return(0.5)

      expect(authority.goal_unattainable?).to be false
    end
  end
end