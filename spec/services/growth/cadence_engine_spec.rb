# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Growth::CadenceEngine do
  subject(:engine) { described_class.new(goal: goal) }

  let(:persona) { create(:persona) }
  let!(:pillar_a) { create(:content_pillar, persona: persona, name: 'Fashion & Style', weight: 20) }
  let!(:pillar_b) { create(:content_pillar, persona: persona, name: 'Food & Cooking', weight: 10) }
  let(:goal) { create(:growth_goal, persona: persona, posts_per_day: 1, max_posts_per_day: 3) }

  before do
    # posts_target = 1*7 = 7; existing 6 => shortfall 1 (single slot).
    allow(engine).to receive(:scheduled_posts_count).and_return(6)
  end

  describe '#sync' do
    # The library lever is the LAST GPU-FREE source of publishable content, and it
    # shipped with no driver -- reachable only by a hand-run rake task, so the
    # plan "spend the library when the runway crosses 72h" had no executor in the
    # drought it was written for. These examples pin the wiring: the tick asks for
    # it when the fresh path left a shortfall, and never when the queue is at target.
    it 'spends the render library when the fresh path leaves a shortfall' do
      spent = Growth::LibraryFallback::Result.new(
        created: 2, rejected: 0, skipped: 0, post_ids: [ 11, 12 ], examined: 3,
        runway_hours: 70.0, budget: 2, triggered: true, reason: nil
      )
      expect(Growth::LibraryFallback).to receive(:new).with(goal: goal)
                                                    .and_return(double(call: spent))
      allow(engine).to receive(:generate_fresh) do
        { success: false, error: 'render refused (comfyui_unclaimed)', run_id: 1 }
      end

      result = engine.sync

      expect(result[:library][:created]).to eq(2)
      expect(result[:library][:post_ids]).to eq([ 11, 12 ])
    end

    it 'never touches the library while the queue is already at target' do
      allow(engine).to receive(:scheduled_posts_count).and_return(7) # target 7, shortfall 0
      expect(Growth::LibraryFallback).not_to receive(:new)

      result = engine.sync

      expect(result[:library]).to be_nil
    end

    it 'swallows a library failure so the tick still reports its own result' do
      allow(Growth::LibraryFallback).to receive(:new).and_raise(StandardError, 'boom')
      allow(engine).to receive(:generate_fresh) do
        { success: false, error: 'render refused', run_id: 1 }
      end

      result = engine.sync

      expect(result[:created]).to eq(0)
      expect(result[:library]).to be_nil
    end

    # PRD 0007 A1 retired the pillar rotation: it existed because an NSFW rejection
    # was pillar-specific, and the classifier is a measurement now. The only failures
    # left are model-wide (render/infra, the realism veto), so the tick stops and lets
    # the brain escalate rather than re-rolling pillars on a fault that is not the
    # pillar's.
    it 'halts the tick on the first render failure instead of rotating pillars' do
      calls = 0
      allow(engine).to receive(:generate_fresh) do
        calls += 1
        { success: false, error: 'render timed out or produced no image', run_id: 3 }
      end

      result = engine.sync

      expect(result[:created]).to eq(0)
      expect(calls).to eq(1)
      expect(result[:failures]).to eq([ 'render timed out or produced no image (run 3)' ])
      expect(Growth::Decision.where(action: 'pillar_shift')).to be_empty
      expect(Growth::Decision.where(action: 'cadence_blocked').count).to eq(1)
    end
  end

  describe '#recover_abandoned' do
    # The GPU-free path: it must never render, and it must stay bounded by the
    # shortfall so an hourly caller cannot over-fill the queue.
    it 'recovers abandoned renders without rendering and bounds the budget by the shortfall' do
      expect(engine).not_to receive(:generate_fresh)
      salvage = Growth::RenderSalvage::Result.new(
        recovered: 1, rejected: 0, skipped: 0, post_ids: [ 42 ], examined: 1
      )
      expect(Growth::RenderSalvage).to receive(:new).with(goal: goal)
                                                   .and_return(double(call: salvage))

      outcome = engine.recover_abandoned

      expect(outcome[:shortfall]).to eq(1)
      expect(outcome[:result]).to eq(salvage)
    end

    it 'does nothing when the queue is already at target — there is nothing to recover into' do
      allow(engine).to receive(:scheduled_posts_count).and_return(7)
      expect(Growth::RenderSalvage).not_to receive(:new)

      outcome = engine.recover_abandoned

      expect(outcome[:shortfall]).to eq(0)
      expect(outcome[:result]).to be_nil
    end
  end

  # `ContentPillar#weight` is the one knob Growth::PersonaEvolution moves, so
  # cadence must actually honour it. It used to `shuffle` the relation, which
  # discarded the weight order entirely and made the lever inert.
  describe '#weighted_pillar_order' do
    it 'lets weight set the render mix while keeping every pillar reachable' do
      firsts = Hash.new(0)
      400.times { firsts[engine.send(:weighted_pillar_order).first.name] += 1 }

      expect(firsts.keys).to contain_exactly('Fashion & Style', 'Food & Cooking')
      # 20 vs 10 → the heavy pillar leads about two thirds of the time. Assert
      # the direction with slack, not the exact ratio (this is a random draw).
      expect(firsts['Fashion & Style']).to be > firsts['Food & Cooking']
      expect(firsts['Fashion & Style']).to be > 200
    end

    it 'never drops a pillar from the order' do
      order = engine.send(:weighted_pillar_order)

      expect(order.map(&:name)).to contain_exactly('Fashion & Style', 'Food & Cooking')
      expect(order.size).to eq(2)
    end
  end
end
