# frozen_string_literal: true

class AutoSelectWinners < GLCommand::Callable
  requires :pipeline_run

  returns :winners, :rejected, :photos

  TOP_K = ENV.fetch("AUTO_SELECT_TOP_K", 3).to_i

  def call
    candidates = gather_candidates
    return if candidates.empty?

    ranked = rank_by_composite_score(candidates)

    winners = ranked.first(TOP_K)
    losers  = ranked[TOP_K..] || []

    context.winners = []
    context.rejected = []
    context.photos = []

    winners.each do |candidate|
      photo = candidate.mark_as_winner!
      if photo
        context.winners << candidate
        context.photos << photo
        Rails.logger.info(
          "AutoSelectWinners: ##{candidate.id} winner — " \
          "tech=#{candidate.quality_score} p_aff=#{pillar_affinity_score(candidate)} " \
          "div=#{diversity_bonus(candidate, winners)} pillar=#{context.pipeline_run.content_pillar&.name}"
        )
      end
    end

    losers.each do |candidate|
      if candidate.quality_score && candidate.quality_score < 15
        candidate.reject!
        context.rejected << candidate
      end
    end

    # Update pillar tracking: record that this pillar was selected
    record_selection

    Rails.logger.info(
      "AutoSelectWinners: Run ##{context.pipeline_run.id} — " \
      "#{context.winners.size} winners, #{context.rejected.size} rejected, " \
      "#{losers.size - context.rejected.size} backup"
    )

    # The pipeline's acceptance counter (PRD 0006 R7 · #77): what this gate let through and
    # what it threw away, emitted where the decision is made rather than mined from logs.
    CharterTelemetry.emit_pipeline_acceptance(
      accepted: context.winners.size,
      rejected: context.rejected.size,
      pillar: context.pipeline_run.content_pillar&.name
    )
  end

  private

  def gather_candidates
    final_step = context.pipeline_run.pipeline.pipeline_steps.order(:order).last
    return [] unless final_step

    ImageCandidate.where(
      pipeline_step: final_step,
      pipeline_run: context.pipeline_run,
      status: "active"
    ).where.not(quality_score: nil)
  end

  def rank_by_composite_score(candidates)
    selected_so_far = []
    # `.to_a`, never `.dup`. `gather_candidates` returns an ActiveRecord::Relation and
    # `Relation#dup` is still a relation, so `remaining.delete(best)` below ran as
    # `DELETE FROM image_candidates WHERE ... AND id = $1` -- "Delete All", measured
    # 2026-10-19. The loop then re-picked the same row off the relation's loaded array and
    # pushed it TOP_K times, so a one-candidate run reported three winners while every
    # candidate it had just ranked was deleted from the database (bypassing callbacks, so a
    # linked photo would have been left dangling). Ranking must not delete anything.
    remaining = candidates.to_a
    ranked = []

    TOP_K.times do
      break if remaining.empty?

      best = remaining.max_by do |c|
        composite = technical_score(c) * 0.5 +
                    pillar_affinity_score(c) * 0.3 +
                    diversity_bonus(c, selected_so_far) * 0.2
        composite
      end

      ranked << best
      selected_so_far << best
      remaining.delete(best)
    end

    ranked + remaining
  end

  # 0-100 normalized technical quality
  def technical_score(candidate)
    (candidate.quality_score || 50).to_f
  end

  # 0-100: how well this pillar performs historically
  def pillar_affinity_score(candidate)
    pillar = context.pipeline_run.content_pillar
    return 50 unless pillar

    # Read engagement score from content strategy state
    state = ContentStrategy::StrategyState.find_by(persona: context.pipeline_run.persona)
    pillar_scores = state&.pillar_engagement_scores || {}

    score = pillar_scores[pillar.name] || 50
    score.to_f.clamp(0, 100)
  end

  # 0-100: penalty for repeating recently-selected pillars
  def diversity_bonus(candidate, already_selected)
    return 50 if already_selected.empty?

    pillar = context.pipeline_run.content_pillar
    return 50 unless pillar

    # Check how many times this pillar was selected in the last batch
    recent_pillars = recent_selections(7)
    same_pillar_count = recent_pillars.count(pillar.name)

    # Bonus decreases as count increases (max 100 for 0, min 0 for 3+)
    [ 100 - (same_pillar_count * 35), 0 ].max
  end

  def recent_selections(days = 7)
    ContentPillars::Photo
      .joins(:content_pillar)
      .where(image_candidate_id: ImageCandidate.where(winner: true).select(:id))
      .where('content_pillars_photos.created_at > ?', days.days.ago)
      .pluck('content_pillars.name')
  rescue
    []
  end

  def record_selection
    state = ContentStrategy::StrategyState.find_or_create_by!(
      persona: context.pipeline_run.persona
    )
    pillar = context.pipeline_run.content_pillar

    history = state.selection_history || []
    history << {
      pillar: pillar&.name,
      run_id: context.pipeline_run.id,
      winners_count: context.winners.size,
      at: Time.current.iso8601
    }
    # Keep last 90 days
    history = history.last(200)

    state.update!(selection_history: history)
  end
end
