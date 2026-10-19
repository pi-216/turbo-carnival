# frozen_string_literal: true

require 'rails_helper'

# PRD 0006 R7 · ticket #77: this command IS the render pipeline's accept gate, so its
# acceptance counter is the one number that says whether the pipeline produced anything --
# a gated pipeline with no acceptance counter is a dead pipeline wearing a heartbeat.
#
# Asserted against the real SDK transport rather than a spy on CharterTelemetry: a spy would
# only show that a call was made, not that a metric reaches the wire.
RSpec.describe AutoSelectWinners do
  include_context 'with sentry telemetry'

  let(:persona) { create(:persona) }
  let(:pipeline) { create(:pipeline) }
  let(:final_step) { create(:pipeline_step, pipeline: pipeline, order: 99) }
  let(:run) { create(:pipeline_run, pipeline: pipeline, persona: persona) }

  def candidate(quality_score)
    create(:image_candidate, pipeline_run: run, pipeline_step: final_step,
                            quality_score: quality_score)
  end

  it 'emits what the gate accepted and what it rejected' do
    candidate(80)
    candidate(70)
    candidate(60)
    candidate(5) # below the 15 rejection floor

    result = described_class.call(pipeline_run: run)

    expect(result.winners.size).to eq(3)
    expect(result.rejected.size).to eq(1)

    accepted = emitted_metrics.find { |m| m[:name] == 'pipeline.render.accepted' }
    rejected = emitted_metrics.find { |m| m[:name] == 'pipeline.render.rejected' }

    expect(accepted[:type]).to eq(:counter)
    expect(accepted[:value]).to eq(3)
    expect(rejected[:type]).to eq(:counter)
    expect(rejected[:value]).to eq(1)
  end

  # `rank_by_composite_score` used to `delete` a candidate off an ActiveRecord::Relation --
  # which is a DELETE, not Array#delete -- so the gate destroyed every candidate it ranked
  # and then reported TOP_K winners off the relation's stale loaded array. Rows ranked must
  # survive ranking; the counter must count rows that still exist.
  it 'ranks without deleting the candidates it ranked' do
    ids = [ candidate(80), candidate(70), candidate(60), candidate(5) ].map(&:id)

    described_class.call(pipeline_run: run)

    expect(ImageCandidate.where(id: ids).count).to eq(4)
  end

  it 'does not report more winners than there are candidates' do
    candidate(80)

    result = described_class.call(pipeline_run: run)

    expect(result.winners.size).to eq(1)
  end

  # A run with no content pillar marks its winners but creates no Photo row, and
  # `mark_as_winner!` used to return that absent row as its own return value -- so the run
  # reported zero winners while three candidates carried `winner: true`. The counter has to
  # read the gate, not the photo bookkeeping.
  it 'still counts a winner on a run with no content pillar, without inventing a pillar name' do
    winner = candidate(80)

    described_class.call(pipeline_run: run)

    accepted = emitted_metrics.find { |m| m[:name] == 'pipeline.render.accepted' }

    expect(winner.reload.winner).to be(true)
    expect(accepted[:value]).to eq(1)
    expect(accepted[:attributes]).not_to have_key(:pillar)
  end
end
