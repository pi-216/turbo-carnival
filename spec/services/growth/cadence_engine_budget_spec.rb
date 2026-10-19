# frozen_string_literal: true

require 'rails_helper'

# The producer runs in the FOREGROUND of the growth tick's timed tool call, so a
# multi-render shortfall used to be SIGKILLed mid-render. These examples pin the
# budget contract: work stops BEFORE a render that cannot finish, the partial
# result is reported (so the next tick knows to top up), and an absent budget
# behaves exactly as before.
RSpec.describe Growth::CadenceEngine do
  let(:persona) { create(:persona) }
  let!(:pillar) { create(:content_pillar, persona: persona, name: 'Fashion & Style', weight: 20) }
  let!(:pillar_b) { create(:content_pillar, persona: persona, name: 'Food & Cooking', weight: 10) }
  let(:goal) { create(:growth_goal, persona: persona, posts_per_day: 1, max_posts_per_day: 3) }

  describe 'budget' do
    it 'is unbounded when no budget is given (previous behaviour)' do
      engine = described_class.new(goal: goal)
      allow(engine).to receive(:scheduled_posts_count).and_return(6)
      allow(engine).to receive(:generate_fresh).and_return(success: true, post_id: 1, photo_id: 2, run_id: 3)

      result = engine.sync

      expect(result[:created]).to eq(1)
      expect(result[:budget_exhausted]).to be(false)
    end

    it 'stops BEFORE starting a render that would not fit the budget' do
      # Budget 100s, one render measures ~300s => nothing fits, so no render is
      # even started. That is the point: a render begun here is the kill.
      engine = described_class.new(goal: goal, budget_seconds: 100)
      allow(engine).to receive(:scheduled_posts_count).and_return(6)
      expect(engine).not_to receive(:generate_fresh)

      result = engine.sync

      expect(result[:created]).to eq(0)
      expect(result[:budget_exhausted]).to be(true)
      expect(result[:shortfall]).to eq(1)
    end

    it 'does the work that fits, then reports the shortfall it left' do
      # A clock that jumps 450s per render: the first check sees elapsed 0 (a
      # render starts), the next sees 450s, and 450 + MEASURED_RENDER_SECONDS
      # (300) no longer fits a 700s budget -- so the second render is never
      # started and the shortfall is reported for the next tick.
      ticks = [ Time.zone.local(2026, 9, 21, 12, 0, 0) ]
      clock = -> { ticks.last }
      engine = described_class.new(goal: goal, budget_seconds: 700, clock: clock)
      allow(engine).to receive(:scheduled_posts_count).and_return(5) # shortfall 2
      calls = 0
      allow(engine).to receive(:generate_fresh) do
        calls += 1
        ticks[0] = ticks.last + 450
        { success: true, post_id: calls, photo_id: calls, run_id: calls }
      end

      result = engine.sync

      expect(result[:created]).to eq(1)
      expect(calls).to eq(1)
      expect(result[:budget_exhausted]).to be(true)
      expect(result[:elapsed_seconds]).to eq(450)
      expect(result[:shortfall]).to eq(1)
    end

    it 'still runs the GPU-free salvage path when the budget is already gone' do
      # The salvage path needs no GPU and is bounded by the shortfall, so the
      # budget must never gate it -- a tick that cannot render can still turn a
      # paid-for abandoned render into a queued post.
      engine = described_class.new(goal: goal, budget_seconds: 1)
      allow(engine).to receive(:scheduled_posts_count).and_return(6)
      salvage_result = Struct.new(:recovered, :rejected, :skipped, :post_ids, :examined)
                             .new(1, 0, 0, [ 99 ], 1)
      allow(Growth::RenderSalvage).to receive(:new).and_return(double(call: salvage_result))
      # After recovery the queue is at target, so nothing is rendered.
      allow(engine).to receive(:scheduled_posts_count).and_return(6, 7)

      result = engine.sync

      expect(result[:salvage][:recovered]).to eq(1)
      expect(result[:created]).to eq(0)
    end
  end
end
