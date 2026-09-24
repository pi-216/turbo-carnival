# frozen_string_literal: true

module Growth
  # Mutates a persona's identity knobs in a bounded, reversible way, always
  # recording a before/after change record so the autonomous experiment can be
  # audited and rolled back. Every decision is conservative: single-step
  # deltas within hard caps, never wholesale resets.
  #
  # Mutatable knobs:
  #   - ContentPillar: weight / priority / active (shift share toward what works)
  #   - Persona.caption_config: tone/style/voice
  #   - Persona.hashtag_strategy: max_tags / brand_tags
  class PersonaEvolution
    WEIGHT_STEP    = 10
    WEIGHT_MIN     = 5
    PRIORITY_MIN   = 1
    PRIORITY_STEP  = 1
    TAG_STEP       = 5
    TAG_MIN        = 3
    TAG_MAX        = 30
    # The pre-experiment hashtag volume. The 10 -> 30 ramp (reviews 2-5) bought
    # no engagement, so the baseline is also the CAP for the broaden lever.
    TAG_BASELINE   = 10

    # A persona's `tone` is authored FREE TEXT ("friendly and approachable",
    # "warm, authentic, conversational"), not an enum — so an exact-match test
    # against a single literal can never see the warmth that is already there.
    # Measured 2026-09-14 (review 5): `:warmer` on a persona whose tone was
    # "friendly and approachable" left the tone untouched, yet recorded the
    # change anyway — a "caption action=warmer" experiment in `applied_changes`
    # that never moved a single knob.
    WARM_TONE_TOKENS = %w[warm friendly approachable cozy inviting kind affectionate
                          gentle cheerful nurturing welcoming].freeze

    attr_reader :goal, :changes

    def initialize(goal:)
      @goal = goal
      @changes = []
    end

    def persona
      goal.persona
    end

    # Shift weight/priority from under-performing pillars to over-performing
    # ones. pillars is [{name:, posts:, engagement:}] ordered strongest first.
    def reweight_toward_top(pillars)
      return [] if pillars.size < 2

      top, *rest = pillars
      bottom = rest.last
      # Only shift if there's a meaningful observed gap and enough throughput
      return [] if top[:posts] < 3 || bottom[:posts] < 3
      return [] if (top[:engagement] - bottom[:engagement]).abs < 0.5

      top_pillar   = find_pillar(top[:name])
      bottom_pillar = find_pillar(bottom[:name])
      return [] unless top_pillar && bottom_pillar

      reward(top_pillar, WEIGHT_STEP, bottom_pillar)
    end

    # Adjust caption tone/style based on what's engaging. action: :warmer/:bolder/:calmer/:balanced
    def adjust_caption(action)
      config = persona.caption_config
      return [] unless config

      tone   = config.tone || 'friendly'
      style  = config.style || 'casual'
      case action
      when :warmer
        # Append rather than replace: the authored voice is the persona, and a
        # bare 'warm' would throw away everything the operator wrote. Idempotent
        # — a second :warmer finds the token already present and changes nothing.
        tone = "#{tone}, warm" unless warm_tone?(tone)
        style = 'intimate' unless style.include?('intimate')
      when :bolder
        tone  = 'confident'
        style = 'bold'
      when :calmer
        tone  = 'calm'
        style = 'minimal'
      when :balanced
        tone  = 'warm'
        style = 'authentic'
      end

      from = { tone: config.tone, style: config.style }
      persona.caption_config = Personas::CaptionConfig.new(config.to_hash.merge(tone: tone, style: style))
      persona.save!
      record(:caption_config, from, { tone: tone, style: style }, "caption action=#{action}")
    end

    # Adjust hashtag volume/count within bounds.
    #
    # BROADENING IS CAPPED AT THE BASELINE (TAG_BASELINE). The "low engagement
    # -> broaden tags" lever was pulled five weeks running (reviews 2-5,
    # 2026-08-24 -> 2026-09-14) taking max_tags 10 -> 30, and per-post
    # engagement never moved (every pillar at or under ~2%, four pillars at
    # 0.0%). Repeating it is not an experiment, it is drift: the review's
    # expand gate now reverts a failed expansion to the baseline, and this
    # bound stops the ramp from being re-walked in the first place. A tag
    # volume ABOVE the baseline is corrected by `enforce_tag_baseline`.
    # Raising the baseline is a policy change (edit the constant, record a
    # review) — deliberately not something a low-engagement week can do.
    def adjust_hashtags(posts:, engagement:)
      strategy = persona.hashtag_strategy || Personas::HashtagStrategy.new
      if posts >= 5 && engagement > 5.0
        from = strategy.to_hash
        reduce_tags(strategy)
        record(:hashtag_strategy, from, persona.hashtag_strategy.to_hash, 'high engagement — tighten tags')
      elsif posts >= 5 && engagement < 1.0 && strategy.max_tags.to_i < TAG_BASELINE
        from = strategy.to_hash
        expand_tags(strategy)
        record(:hashtag_strategy, from, persona.hashtag_strategy.to_hash, 'low engagement — broaden tags')
      end
    end

    # Pull a persona back to the tag baseline when it sits above it — the
    # cleanup for the disproven broaden ramp, and the reason the ramp cannot
    # survive a review as a stale value in the DB. Records the change so the
    # ledger shows why the volume moved (never a silent edit).
    def enforce_tag_baseline
      strategy = persona.hashtag_strategy || Personas::HashtagStrategy.new
      current = strategy.max_tags.to_i
      return nil if current <= TAG_BASELINE

      from = strategy.to_hash
      persona.hashtag_strategy = Personas::HashtagStrategy.new(
        strategy.to_hash.merge(max_tags: TAG_BASELINE)
      )
      persona.save!
      record(:hashtag_strategy, from, persona.hashtag_strategy.to_hash,
             "tag volume above the #{TAG_BASELINE} baseline — reverting the disproven broaden ramp")
    end

    private

    # Does this free-text tone already read as warm? Tokenised, so
    # "friendly and approachable" and "warm, authentic, conversational" both
    # count — the exact-match test that used to live here did not.
    def warm_tone?(tone)
      words = tone.to_s.downcase.scan(/[a-z]+/)
      (words & WARM_TONE_TOKENS).any?
    end

    def find_pillar(name)
      persona.content_pillars.current.find { |p| p.name.casecmp?(name) }
    end

    def reward(pillar, step, penalty_pillar)
      from = { id: pillar.id, weight: pillar.weight, priority: pillar.priority }
      p_from = { id: penalty_pillar.id, weight: penalty_pillar.weight, priority: penalty_pillar.priority }

      # Compute both new weights FIRST so the total never transiently exceeds
      # 100% (the ContentPillar validation would otherwise reject the reward
      # before the penalty brings the sum back down).
      new_bottom_weight = [ penalty_pillar.weight - step, WEIGHT_MIN ].max
      transfer = penalty_pillar.weight - new_bottom_weight   # actual share freed
      new_top_weight    = [ pillar.weight + transfer, 100 ].min

      new_top_priority    = [ pillar.priority + PRIORITY_STEP, 5 ].min
      new_bottom_priority = [ penalty_pillar.priority - PRIORITY_STEP, PRIORITY_MIN ].max

      ContentPillar.transaction do
        penalty_pillar.update!(weight: new_bottom_weight, priority: new_bottom_priority)
        pillar.update!(weight: new_top_weight, priority: new_top_priority, active: true)
      end

      recorded = []
      recorded << record(:content_pillar, from, { id: pillar.id, weight: pillar.weight, priority: pillar.priority }, "reward #{pillar.name}")
      recorded << record(:content_pillar, p_from, { id: penalty_pillar.id, weight: penalty_pillar.weight, priority: penalty_pillar.priority }, "penalize #{penalty_pillar.name}")
      recorded.compact
    end

    def reduce_tags(strategy)
      max = strategy.max_tags.to_i
      brand = Array(strategy.brand_tags || [])
      persona.hashtag_strategy = Personas::HashtagStrategy.new(
        strategy.to_hash.merge(max_tags: [ [ max - TAG_STEP, TAG_MIN ].max, 1 ].max)
      )
      persona.save!
    end

    def expand_tags(strategy)
      max = strategy.max_tags.to_i
      persona.hashtag_strategy = Personas::HashtagStrategy.new(
        strategy.to_hash.merge(max_tags: [ [ max + TAG_STEP, TAG_MAX ].min, 1 ].max)
      )
      persona.save!
    end

    def record(kind, from, to, reason)
      # A recorded "change" that changed nothing is a false experiment: the
      # review's gate evaluation reads `applied_changes` to decide whether a
      # lever worked, so a no-op inflates that ledger and can never be
      # evaluated honestly. Refuse to record one — and SAY so, because the
      # absence of an applied change is otherwise indistinguishable from a
      # lever nobody pulled.
      if from == to
        Rails.logger.info(
          "[growth] #{kind} lever inert for persona #{persona.id} (#{reason}): " \
          "already at target #{from.inspect} — nothing recorded"
        )
        return nil
      end

      change = { kind: kind, from: from, to: to, reason: reason, at: Time.current }
      @changes << change
      change
    end
  end
end
