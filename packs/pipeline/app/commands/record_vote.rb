class RecordVote < GLCommand::Callable
  requires :winner, :loser

  def call
    # Validate that winner and loser are different
    if context.winner.id == context.loser.id
      stop_and_fail!("Cannot vote for the same image against itself")
    end

    ActiveRecord::Base.transaction do
      # Create vote record to track this matchup
      Vote.create!(
        winner_id: context.winner.id,
        loser_id: context.loser.id
      )

      winner_change = context.winner.calculate_elo_change(context.loser, true)
      loser_change = context.loser.calculate_elo_change(context.winner, false)

      context.winner.update!(
        elo_score: context.winner.elo_score + winner_change,
        vote_count: context.winner.vote_count + 1
      )
      context.loser.update!(
        elo_score: context.loser.elo_score + loser_change,
        vote_count: context.loser.vote_count + 1
      )
    end
  end

  def rollback
    # GLCommand handles transaction rollback automatically
  end
end
