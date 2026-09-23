# frozen_string_literal: true

require 'rails_helper'
require 'sidekiq/api'

# The recovery must be driven by the always-on worker, NOT by a tick that has to
# acquire the 4090 -- that was the gap: RenderSalvage had a purpose-built
# GPU-free entry point (CadenceEngine#recover_abandoned) with no driver, so
# abandoned renders waited for the next GPU-acquiring tick (13h+ measured).
RSpec.describe Growth::AbandonedRenderWorker do
  let(:persona) { create(:persona) }
  let!(:goal) { create(:growth_goal, persona: persona, posts_per_day: 1, max_posts_per_day: 3) }

  before do
    # Keep the self-rescheduling loop offline (no Redis, no real enqueue).
    allow(Sidekiq::ScheduledSet).to receive(:new).and_return([])
    allow(described_class).to receive(:perform_in)
  end

  def salvage_result(recovered)
    Struct.new(:recovered, :rejected, :skipped, :post_ids, :examined)
          .new(recovered, 0, 0, recovered.positive? ? [ 7 ] : [], recovered)
  end

  it 'asks the engine to recover with the ACTIVE goal' do
    engine = instance_double(Growth::CadenceEngine)
    expect(Growth::CadenceEngine).to receive(:new).with(goal: goal).and_return(engine)
    expect(engine).to receive(:recover_abandoned)
      .and_return(target: 3, existing: 2, shortfall: 1, result: salvage_result(1))
    # Shortfall still open after recovery => the library is asked too.
    expect(engine).to receive(:top_up_from_library).and_return(nil)

    described_class.new.perform
  end

  it 'does NOT ask for the library when recovery closed the whole shortfall' do
    engine = instance_double(Growth::CadenceEngine)
    allow(Growth::CadenceEngine).to receive(:new).and_return(engine)
    allow(engine).to receive(:recover_abandoned)
      .and_return(target: 3, existing: 3, shortfall: 0, result: nil)
    expect(engine).not_to receive(:top_up_from_library)

    described_class.new.perform
  end

  # The library lever had NO driver at all: reachable only by a hand-run rake
  # task. The always-on loop is the driver, and it must keep running when the
  # library itself fails (a fallback may never break the loop that carries it).
  it 'survives a library failure' do
    engine = instance_double(Growth::CadenceEngine)
    allow(Growth::CadenceEngine).to receive(:new).and_return(engine)
    allow(engine).to receive(:recover_abandoned)
      .and_return(target: 3, existing: 2, shortfall: 1, result: nil)
    allow(engine).to receive(:top_up_from_library).and_raise(StandardError, 'boom')

    expect { described_class.new.perform }.not_to raise_error
  end

  it 'does nothing when no goal is active' do
    allow(Growth::Goal).to receive(:active).and_return(Growth::Goal.none)
    expect(Growth::CadenceEngine).not_to receive(:new)

    described_class.new.perform
  end

  it 'swallows a recovery failure so the loop keeps running' do
    engine = instance_double(Growth::CadenceEngine)
    allow(Growth::CadenceEngine).to receive(:new).and_return(engine)
    allow(engine).to receive(:recover_abandoned).and_raise(StandardError, 'boom')

    expect { described_class.new.perform }.not_to raise_error
  end

  it 'reschedules itself on the interval' do
    allow(Growth::Goal).to receive(:active).and_return(Growth::Goal.none)
    expect(described_class).to receive(:perform_in).with(described_class::INTERVAL_SECONDS)

    described_class.new.perform
  end

  it 'does not stack a second copy of the loop' do
    allow(Growth::Goal).to receive(:active).and_return(Growth::Goal.none)
    scheduled = [ double(klass: described_class.name) ]
    allow(Sidekiq::ScheduledSet).to receive(:new).and_return(scheduled)
    expect(described_class).not_to receive(:perform_in)

    described_class.new.perform
  end
end
