# frozen_string_literal: true

# Growth Harness dashboard: goal trajectory + decision log
class GrowthController < ApplicationController
  def index
    @goals = Growth::Goal.includes(:persona, :snapshots, :decisions).order(created_at: :desc)

    @selected_goal =
      if params[:goal_id]
        Growth::Goal.find(params[:goal_id])
      else
        @goals.first
      end

    @snapshots = @selected_goal&.snapshots&.order(taken_at: :asc) || []
    @decisions = @selected_goal&.decisions&.order(decided_at: :desc)&.limit(20) || []
  end

  def sync_cadence
    goal = Growth::Goal.find(params[:goal_id])
    result = Growth::CadenceEngine.new(goal: goal).sync
    redirect_to growth_path(goal_id: goal.id),
                notice: "Cadence sync: created #{result[:created]} posts (queue #{result[:existing]}→#{result[:existing] + result[:created]})"
  end

  def snapshot
    goal = Growth::Goal.find(params[:goal_id])
    snap = Growth::MetricsCollector.new(goal: goal).collect
    if snap
      redirect_to growth_path(goal_id: goal.id), notice: "Snapshot captured: #{snap.followers} followers"
    else
      redirect_to growth_path(goal_id: goal.id), alert: "Snapshot failed — see decision log for reason"
    end
  end

  def review
    goal = Growth::Goal.find(params[:goal_id])
    result = Growth::StrategyBrain.new(goal: goal).review(force: true)
    redirect_to growth_path(goal_id: goal.id), notice: "Review: #{result.inspect}"
  end
end
