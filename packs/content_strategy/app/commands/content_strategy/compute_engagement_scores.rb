# frozen_string_literal: true

module ContentStrategy
  class ComputeEngagementScores < GLCommand::Callable
    def call
      persona = Persona.find_by(name: "Sarah")
      return unless persona

      pillar_scores = compute_pillar_scores(persona)
      store_scores(persona, pillar_scores)
      update_candidate_scores(persona)

      Rails.logger.info(
        "ComputeEngagementScores: #{pillar_scores.size} pillars scored. " \
        "Top: #{pillar_scores.max_by { |_, v| v }&.first}"
      )
    end

    private

    def compute_pillar_scores(persona)
      scores = {}
      pillars = persona.content_pillars.where(active: true)

      pillars.each do |pillar|
        posts = Scheduling::Post
          .joins(:photo)
          .where(persona_id: persona.id, status: "posted")
          .where(photos: { content_pillar_id: pillar.id })
          .where("scheduling_posts.posted_at > ?", 28.days.ago)
          .where.not(engagement_rate: nil)

        if posts.any?
          avg_engagement = posts.average(:engagement_rate).to_f.round(2)
          total_likes = posts.sum(:likes_count)
          trend = compute_trend(posts)

          scores[pillar.name] = {
            avg_engagement: avg_engagement,
            total_likes: total_likes,
            posts_count: posts.count,
            trend: trend
          }
        else
          scores[pillar.name] = {
            avg_engagement: 0,
            total_likes: 0,
            posts_count: 0,
            trend: :new
          }
        end
      end

      # Normalize to 0-100 scores based on how they compare to each other
      normalize_scores(scores)
    end

    def normalize_scores(scores)
      engagements = scores.values.map { |s| s[:avg_engagement] }
      max_eng = engagements.max
      min_eng = engagements.min
      range = max_eng - min_eng

      scores.each do |name, data|
        if range.positive?
          normalized = ((data[:avg_engagement] - min_eng) / range * 60 + 40).round(1)
        else
          normalized = 50.0
        end

        # Trending up? Bonus. Trending down? Penalty.
        case data[:trend]
        when :rising then normalized = [ normalized + 10, 100 ].min
        when :falling then normalized = [ normalized - 10, 0 ].max
        end

        data[:normalized_score] = normalized
      end

      scores
    end

    def compute_trend(posts)
      recent = posts.where("scheduling_posts.posted_at > ?", 14.days.ago).average(:engagement_rate).to_f
      older  = posts.where("scheduling_posts.posted_at <= ?", 14.days.ago)
                    .where("scheduling_posts.posted_at > ?", 28.days.ago)
                    .average(:engagement_rate).to_f

      return :new if older.zero?
      return :stable if (recent - older).abs < 0.5
      recent > older ? :rising : :falling
    end

    def store_scores(persona, pillar_scores)
      state = ContentStrategy::StrategyState.find_or_create_by!(persona: persona)

      pillar_engagement = pillar_scores.transform_values { |v| v[:normalized_score] }
      state.update!(pillar_engagement_scores: pillar_engagement)
    end

    def update_candidate_scores(persona)
      state = ContentStrategy::StrategyState.find_by(persona: persona)
      return unless state

      scores = state.pillar_engagement_scores || {}

      ImageCandidate.where(status: "active").where.not(quality_score: nil).find_each do |candidate|
        pillar = candidate.pipeline_run&.content_pillar
        next unless pillar

        engagement = scores[pillar.name] || 50
        composite = ((candidate.quality_score.to_f * 0.6) + (engagement.to_f * 0.4)).round(1)
        candidate.update_column(:engagement_score, composite)
      end
    end
  end
end
