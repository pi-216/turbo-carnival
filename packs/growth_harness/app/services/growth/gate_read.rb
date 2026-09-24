# frozen_string_literal: true

module Growth
  # The PRE-REGISTERED GO/PIVOT/KILL gate for the growth thesis, as a READ.
  #
  # The gate was registered on the ops board (key `growth-strategy-gate`) as a
  # criterion in PROSE: "if followers < 170 AND no pillar exceeds 3% average
  # engagement by that review, the thesis gets a GO/PIVOT/KILL decision rather
  # than another tuning pass". Prose does not survive a hand-off. The cohort
  # validity rule below -- which decides whether the engagement leg is a
  # MEASUREMENT at all -- took a full ops pass to derive from the data, and a
  # reader who skips it reads a pre-intervention cohort as a strategy verdict,
  # which is how a live experiment gets killed on evidence it could not have
  # produced. This class makes the whole read mechanical and testable so the
  # 2026-09-28 and 2026-10-05 reads cannot disagree with each other.
  #
  # Read-only: no writes, no persona mutation, no gate reverts. Safe at any time.
  #
  # The engagement leg is measured ON THE COHORT, never on the raw window (see
  # #call): a window that still holds pre-intervention renders would otherwise
  # let content the levers never touched decide the leg. The window-wide maximum
  # is reported as `engagement[:window_max]` for context.
  class GateRead
    # The two locked legs of the criterion. Thresholds are NOT tunable here --
    # changing one is a decision to change the pre-registration, not a config.
    FOLLOWER_CEILING        = 170   # followers must reach this for the follower leg to pass
    PILLAR_ENGAGEMENT_FLOOR = 3.0   # some pillar must EXCEED this avg engagement (%) to pass

    # The content-mix and caption levers landed 2026-09-21T23:35Z (backup:
    # ops/backups/content-mix-20260921T233509Z.json). A post RENDERED before this
    # instant cannot carry any lever's effect, so it cannot vote on the gate --
    # publication lags the render by the queue depth (measured ~7 days here).
    INTERVENTION_AT = Time.utc(2026, 9, 21, 23, 35)

    # Published, insights-bearing, POST-intervention posts required inside the
    # review window before the engagement leg is a valid measurement. Below this
    # the leg reads :extend -- the pre-committed handling, registered before the
    # read, is to re-read rather than to act on an unobservable cohort.
    MIN_COHORT_POSTS = 5

    def initialize(goal:)
      @goal = goal
    end

    def call
      inputs    = review.gate_inputs
      # The leg an intervention can be judged by: the COHORT, never the raw
      # window. "A post RENDERED before this instant cannot carry any lever's
      # effect, so it cannot vote on the gate" (see INTERVENTION_AT) is a
      # property of the SET this leg reads, and the window still holds
      # pre-intervention renders while the pool fills -- publication lags the
      # render by the queue depth. Measured 2026-09-24: reading the unfiltered
      # window let a pillar whose EVERY post predates the levers be the gate's
      # "top pillar" and pass the leg on content the intervention never touched.
      # The unfiltered maximum is reported beside it so the difference is
      # visible, not silent.
      cohort_scope   = cohort_posts(inputs)
      pillars        = review.pillar_stats(cohort_scope)
      window_pillars = inputs[:pillars]
      top        = pillars.first
      window_top = window_pillars.first
      followers  = @goal.latest_followers.to_i
      max_eng    = top ? top[:engagement].to_f : 0.0
      window_max = window_top ? window_top[:engagement].to_f : 0.0

      follower_pass   = followers >= FOLLOWER_CEILING
      engagement_pass = max_eng > PILLAR_ENGAGEMENT_FLOOR
      cohort          = cohort_scope.count
      cohort_valid    = cohort >= MIN_COHORT_POSTS

      {
        verdict: verdict_for(follower_pass, engagement_pass, cohort_valid),
        reason: reason_for(follower_pass, engagement_pass, cohort_valid, cohort),
        followers: { value: followers, ceiling: FOLLOWER_CEILING, pass: follower_pass },
        engagement: {
          max_pillar: top && top[:name], max: max_eng, floor: PILLAR_ENGAGEMENT_FLOOR,
          pass: engagement_pass, window_days: inputs[:window_days],
          window_posts: inputs[:window_posts].count,
          measured_on: 'cohort',
          window_max: window_max, window_max_pillar: window_top && window_top[:name],
          cohort: cohort, cohort_valid: cohort_valid, min_cohort: MIN_COHORT_POSTS
        },
        pillars: pillars
      }
    end

    # Posts that can actually testify about the intervention: published inside the
    # review window, RENDERED at/after INTERVENTION_AT, and carrying collected
    # insights. Keyed on the render (photo) rather than the publish date, because
    # the publish date lags the render by the queue depth. `inputs` is
    # `review.gate_inputs` when the caller already has it (so the window relation
    # and its per-pillar stats are built once, not per caller).
    def cohort_posts(inputs = nil)
      (inputs || review.gate_inputs)[:window_posts]
        .joins(:photo)
        .where('photos.created_at >= ?', INTERVENTION_AT)
        .where.not(insights_updated_at: nil)
    end

    def cohort_size
      cohort_posts.count
    end

    private

    def review
      @review ||= Growth::WeeklyReview.new(goal: @goal)
    end

    # The pre-registered mapping, in the order the criterion reads:
    #   :extend     -- the engagement leg is not a measurement yet (cohort too
    #                  small); re-read, do NOT act. Takes precedence over both
    #                  pass and fail, because an invalid leg can only mislead.
    #   :go         -- both legs pass: keep producing.
    #   :gate_fires -- both legs fail: the locked conjunction fires, so a
    #                  GO/PIVOT/KILL decision is required (not another tuning pass).
    #   :continue   -- one leg fails: the pre-registered conjunction has not
    #                  fired; keep the experiment running and re-read.
    def verdict_for(follower_pass, engagement_pass, cohort_valid)
      return :extend unless cohort_valid
      return :go if follower_pass && engagement_pass
      return :gate_fires if !follower_pass && !engagement_pass

      :continue
    end

    def reason_for(follower_pass, engagement_pass, cohort_valid, cohort)
      unless cohort_valid
        return "engagement leg is NOT a measurement yet: only #{cohort} post-intervention " \
               "post(s) with insights in the window (need #{MIN_COHORT_POSTS}); " \
               'the 09-21 levers have no published cohort -- EXTEND, do not act'
      end
      return 'both legs pass -- keep producing' if follower_pass && engagement_pass
      if !follower_pass && !engagement_pass
        return 'gate FIRES: followers below the ceiling AND no pillar above the floor on a ' \
               'valid cohort -- GO/PIVOT/KILL decision required (pivot candidate: distribution/reach, ' \
               'not another content lever)'
      end

      'one leg fails -- the locked conjunction has not fired; re-read at the next review'
    end
  end
end
