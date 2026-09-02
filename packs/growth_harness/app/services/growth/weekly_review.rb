# frozen_string_literal: true

module Growth
  # The weekly "step back and revisit the whole picture" step of the harness.
  #
  # Runs a full audit each week (or on force):
  #   1. Follower trajectory vs the goal (on/behind/ahead/flat/need_data)
  #   2. Per-pillar content performance from real post insights
  #   3. A narrative read on the persona's direction
  #   4. Conservative persona evolution (bounded, reversible) — shift the
  #      identity/content mix toward what's working, evolve the persona over time
  #   5. Recommendations for the coming week (experiments to run)
  #
  # Everything is recorded in a Growth::Review for auditability/reversibility.
  class WeeklyReview
    # Minimum evidence before the brain is allowed to mutate the persona.
    MIN_SNAPSHOTS  = 2
    MIN_POSTS_TOTAL = 5   # across all pillars before reweighting
    MIN_POSTS_PILLAR = 3  # per pillar before its engagement is trusted
    TRAJ_EQUAL_OK   = 0.5
    # Gate margins for the persona experiment: these pre-register the
    # falsifiable expectation that must hold for a change to "stick" on the
    # following week's review. If the gate fails, the change is reverted.
    GATE_REWARD_ENGAGEMENT  = 4.0   # rewarded pillar must sustain >= this avg
    GATE_REWARD_MIN_POSTS   = 3     # and must post at least this many more
    GATE_TAG_ENGAGEMENT     = 5.0   # tighten-tags decision bound

    attr_reader :goal

    def initialize(goal:)
      @goal = goal
    end

    # Returns the created Growth::Review. With `apply: false` it only audits
    # (dry-run) without mutating the persona / writing a review.
    def review(apply: true, force: false)
      return build_review(need_data_review) if evidence_for_verdict.nil?

      gate_results = evaluate_previous_gates
      audit = gather_audit
      persona_dir = persona_direction(audit)
      evolution = apply ? PersonaEvolution.new(goal: goal) : nil

      recommendations = recommend(audit, gate_results)
      changes = Array(gate_results[:actions])

      if apply && audit[:verdict] == 'declining'
        # CONCLUSION STATE: followers are leaving. The strategy is broken, not
        # behind — reweighting pillars / tweaking tags / warming captions on a
        # shrinking audience adds noise, not signal. Record the review as-is and
        # make NO persona changes; recommend diagnosis instead.
        changes << {
          kind: 'halt_persona_evolution',
          from: {}, to: {},
          reason: 'declining verdict — net follower loss; strategy broken, diagnosing root cause before any change'
        }
      elsif apply
        changes += (evolution&.reweight_toward_top(audit[:pillars]) || [])
        total_posts = audit[:pillars].sum { |p| p[:posts] }
        avg_eng = average_engagement(audit[:pillars])
        changes += [evolution.adjust_hashtags(posts: total_posts, engagement: avg_eng)] if total_posts >= 5
        changes.compact!
        # Only evolve captions when clearly warranted (strong signal).
        if audit.fetch(:caption_signal, :none) != :none
          cap = evolution&.adjust_caption(audit[:caption_signal])
          changes += Array.wrap(cap)
        end
      end

      review = Growth::Review.create!(
        goal: goal,
        reviewed_at: Time.current,
        followers: goal.latest_followers,
        followers_delta: audit[:followers_delta],
        required_daily: goal.required_daily_growth,
        measured_daily: goal.average_daily_growth,
        trajectory_ratio: goal.traj_ratio,
        verdict: audit[:verdict],
        pillar_engagement: audit[:pillars].each_with_object({}) { |p, h| h[p[:name]] = p },
        top_pillars: audit[:pillars].map { |p| p[:name] },
        persona_direction: persona_dir,
        recommendations: recommendations,
        applied_changes: changes
      )

      build_review(review)
    end

    private

    # Returns verdict nil when we need more data (so caller skips audit work).
    def evidence_for_verdict
      return nil if goal.snapshots.count < MIN_SNAPSHOTS
      return nil if posted_posts.count < MIN_POSTS_TOTAL

      :enough
    end

    def build_review(obj)
      { review: obj, verdict: obj.respond_to?(:verdict) ? obj.verdict : obj[:verdict] }
    end

    def need_data_review
      {
        verdict: 'need_data',
        followers: goal.latest_followers,
        snapshots: goal.snapshots.count,
        posts: posted_posts.count
      }
    end

    def gather_audit
      snapshots = goal.snapshots.order(taken_at: :asc)
      newest = goal.latest_snapshot
      oldest = snapshots.first
      delta = newest ? newest.followers - oldest.followers : 0
      measured = goal.average_daily_growth

      pillars = pillar_stats
      hashtag_signal = hashtag_signal(pillars)
      caption_signal = caption_signal(pillars)

      {
        followers_delta: delta,
        measured: measured,
        verdict: classify(delta, measured),
        pillars: pillars,
        hashtag_signal: hashtag_signal,
        caption_signal: caption_signal
      }
    end

    def classify(delta, measured)
      ratio = goal.traj_ratio
      # Net follower LOSS — the conclusion state: "broken", not merely "behind".
      # Escalation/tuning on a shrinking audience only adds noise, so this
      # verdict halts persona mutation (see review) and forces diagnosis.
      return 'declining' if measured.to_f.negative? || delta.negative?
      return 'flat' if ratio.nil? || (measured.to_f.abs < 0.01 && delta.abs <= TRAJ_EQUAL_OK)
      return 'ahead' if ratio >= 1.5
      return 'behind' if ratio < 1.0

      'on_track'
    end

    # Aggregate engagement per content pillar from posted posts + insights.
    def pillar_stats
      rows = {}
      posted_posts.includes(photo: :content_pillar).find_each do |post|
        pillar_name = post.photo&.content_pillar&.name || 'Uncategorized'
        r = (rows[pillar_name] ||= { name: pillar_name, posts: 0, engagement: 0.0, reach: 0, likes: 0, saved: 0, follows_est: 0 })
        r[:posts] += 1
        r[:engagement] += post.engagement_rate.to_f || 0
        r[:reach] += post.reach.to_i || 0
        r[:likes] += post.likes_count.to_i || 0
        r[:saved] += (post.saved_count.to_i || 0)
      end
      rows.values.map do |r|
        avg = r[:posts].positive? ? (r[:engagement] / r[:posts]).round(3) : 0.0
        { name: r[:name], posts: r[:posts], engagement: avg, reach: r[:reach], likes: r[:likes], saved: r[:saved] }
      end.sort_by { |p| [-p[:engagement], -p[:posts]] }
    end

    def hashtag_signal(pillars)
      strong = pillars.any? { |p| p[:engagement] > 5.0 && p[:posts] >= MIN_POSTS_PILLAR }
      weak = pillars.any? { |p| p[:engagement] < 1.0 && p[:posts] >= MIN_POSTS_PILLAR }
      { engagement_present: strong || weak, strong: strong, weak: weak }
    end

    def caption_signal(pillars)
      return :none unless pillars.any? { |p| p[:posts] >= MIN_POSTS_PILLAR }

      top = pillars.first
      return :warmer if top && top[:engagement] >= 4.0
      return :bolder if top && top[:engagement] >= 6.0
      return :none
    end

    def persona_direction(audit)
      return nil if audit[:verdict] == 'need_data'

      top = audit[:pillars].first
      dir = []
      dir << "Leading on #{top[:name]}(#{top[:engagement]}% avg)" if top
      case audit[:verdict]
      when 'on_track' then dir << 'sustaining; refining identity toward strengths'
      when 'behind'   then dir << 'underperforming; pivoting content mix and cadence up'
      when 'ahead'    then dir << 'over-performing; consolidating gains'
      when 'flat'     then dir << 'stalled; bolder experimentation warranted'
      when 'declining' then dir << 'net follower loss — strategy is BROKEN, not just behind; halting persona tuning and diagnosing root cause (content quality, gates, audience fit)'
      end
      dir.join(' — ')
    end

    def recommend(audit, gate_results = {})
      if audit[:verdict] == 'declining'
        # Broken state: no tuning advice — halt and diagnose. Posting MORE to a
        # shrinking audience is exactly the wrong experiment to run this week.
        return [
          'HALT cadence increases — followers are LEAVING (net loss); scale output back, do not post more to a shrinking audience',
          'Diagnose root cause before any next step: content quality/gates (NSFW + realism rejection rates as proxies), engagement of last 10 posts vs first 10, audience fit'
        ]
      end

      recs = []
      if gate_results[:kept]&.any?
        recs << "Gates met: kept last week's changes (#{gate_results[:kept].join(', ')})"
      end
      if gate_results[:reverted]&.any?
        recs << "Gates FAILED: reverted last week's changes (#{gate_results[:reverted].join(', ')})"
      end
      top = audit[:pillars].first
      bottom = audit[:pillars].last
      if top && top[:engagement] >= 4.0
        recs << "Double down on #{top[:name]} — create 2x variations of what resonates"
      end
      if bottom && bottom[:engagement] < 1.0 && bottom[:posts] >= MIN_POSTS_PILLAR
        recs << "Retire or rethink #{bottom[:name]} — near-zero engagement, tries new angle or drops"
      end
      recs << 'Test different posting times / Reels vs feed' if audit[:verdict] == 'flat'
      recs << 'Escalate cadence toward daily if trajectory stays behind' if audit[:verdict] == 'behind'
      recs.empty? ? ['Continue current strategy — all nominal'] : recs
    end

    # Check whether the persona changes applied last review met their
    # pre-registered gates; revert any that failed. Returns {actions:[...], kept:[], reverted:[]}.
    def evaluate_previous_gates
      prev = goal.reviews.order(reviewed_at: :desc).first
      return { actions: [], kept: [], reverted: [] } unless prev&.applied_changes&.any?

      current_pillars = pillar_stats
      actions = []
      kept = []
      reverted = []

      prev.applied_changes.each do |change|
        # Defensive: older/buggy records may hold a flattened pair-array, not a
        # Hash (see Array(hash) collapse bug). Skip non-hashes so legacy rows
        # can't crash the gate eval.
        next unless change.is_a?(Hash) && change['kind'].is_a?(String)

        kind = change['kind']
        case kind
        when 'content_pillar'
          # A reweight happened last week. Check the *rewarded* pillar held up.
          from, to = change['from'], change['to']
          # to has higher weight/priority → it was the rewarded one.
          if to && from && to['weight'].to_i > from['weight'].to_i
            name = change['reason'].to_s.sub('reward ', '')
            result = eval_reward_pillar_gate(name, current_pillars)
            if result
              kept << name
            else
              revert_content_pillar(from)
              reverted << name
              actions << { kind: 'revert_content_pillar', from: from, reason: "gate failed for #{name}" }
            end
          end
        when 'hashtag_strategy'
          # Only gate the tighten direction (meaningful to test).
          from, to = change['from'], change['to']
          if to && from && to['max_tags'].to_i < from['max_tags'].to_i
            avg_eng = average_engagement(current_pillars)
            if avg_eng >= GATE_TAG_ENGAGEMENT
              kept << 'tighten-tags'
            else
              # trajectory didn't reward it → relax tags back
              relax_tags(from)
              reverted << 'tighten-tags'
              actions << { kind: 'revert_hashtags', from: from, reason: "tighten-tags gate failed" }
            end
          end
        end
      end

      { actions: actions, kept: kept, reverted: reverted }
    end

    def eval_reward_pillar_gate(name, pillars)
      p = pillars.find { |x| x[:name].casecmp?(name) || x[:name].downcase.include?(name.downcase) }
      return false if p.nil?

      # Gate: the rewarded pillar must sustain strong engagement AND keep
      # posting (minimal new-post throughput) for the change to have worked.
      p[:engagement] >= GATE_REWARD_ENGAGEMENT && p[:posts] >= GATE_REWARD_MIN_POSTS
    end

    def average_engagement(pillars)
      return 0.0 if pillars.empty?

      (pillars.sum { |p| p[:engagement] } / pillars.size).round(3)
    end

    def revert_content_pillar(from)
      p = ContentPillar.find_by(id: from['id'])
      return unless p

      p.update!(weight: from['weight'], priority: from['priority'])
    end

    def relax_tags(from)
      persona = goal.persona
      persona.hashtag_strategy = Personas::HashtagStrategy.new(
        from.merge(max_tags: from['max_tags'].to_i)
      )
      persona.save!
    end

    def posted_posts
      Scheduling::Post
        .where(persona: goal.persona)
        .where(status: 'posted')
        .where.not(photo_id: nil)
    end
  end
end