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
  #
  # The cohort's ERASURE is reported beside it (`removal`, printed by both call
  # sites). Instagram has removed 36 of the 150 posts this app published, and the
  # erasure is invisible to the verdict in BOTH directions: a post removed after
  # its insights were collected still votes, with post-erasure zeros, and one
  # removed before collection silently leaves the cohort -- so a wave can look
  # like a failed lever OR like "not enough data yet". See #removal_accounting.
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
      removal        = removal_accounting(inputs)
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
        reason: reason_for(follower_pass, engagement_pass, cohort_valid, cohort) +
                removal_clause(removal),
        followers: { value: followers, ceiling: FOLLOWER_CEILING, pass: follower_pass },
        engagement: {
          max_pillar: top && top[:name], max: max_eng, floor: PILLAR_ENGAGEMENT_FLOOR,
          pass: engagement_pass, window_days: inputs[:window_days],
          window_posts: inputs[:window_posts].count,
          measured_on: 'cohort',
          window_max: window_max, window_max_pillar: window_top && window_top[:name],
          cohort: cohort, cohort_valid: cohort_valid, min_cohort: MIN_COHORT_POSTS
        },
        pillars: pillars,
        removal: removal
      }
    end

    # Posts that can actually testify about the intervention: published inside the
    # review window, RENDERED at/after INTERVENTION_AT, and carrying collected
    # insights. Keyed on the render (photo) rather than the publish date, because
    # the publish date lags the render by the queue depth. `inputs` is
    # `review.gate_inputs` when the caller already has it (so the window relation
    # and its per-pillar stats are built once, not per caller).
    #
    # `insights_updated_at` is not "eventually" -- it is bounded by a HARD age gate
    # in the collector, and that bound is what makes this cohort predictable:
    # Scheduling::Commands::CollectPostInsights#posts_needing_insights only selects
    # `posted_at < 24.hours.ago` (hourly, 25 rows/run, never-collected first), so a
    # post cannot enter the cohort until it is >24h old, and measured first
    # collection runs 31-53h after publish (the 25-row budget is saturated at the
    # current cadence). Consequence, and why the two pre-registered reads land where
    # they do: a read at time T can only count posts published up to ~T-24h.
    # Measured 2026-09-24 against the queue -- the forced 09-28 13:00Z read sees
    # cohort ~1 (only the 09-27 posts are old enough) -> :extend, and the 10-05
    # 13:00Z read sees 9 post-intervention posts (351..360, all published 09-28
    # 14:00Z..10-01 10:30Z, all >24h old by then) -> a VALID read, so the gate
    # fires there rather than extending again. Size any future read off that gate,
    # never off the queue's clock count.
    def cohort_posts(inputs = nil)
      post_intervention_posts(inputs).where.not(insights_updated_at: nil)
    end

    # The candidate POOL the cohort is drawn from: posts inside the review window
    # whose RENDER is post-intervention, with no insights filter. Split out from
    # #cohort_posts so the ERASURE of a candidate is measurable -- see
    # #removal_accounting.
    def post_intervention_posts(inputs = nil)
      (inputs || review.gate_inputs)[:window_posts]
        .joins(:photo)
        .where('photos.created_at >= ?', INTERVENTION_AT)
    end

    # Removal accounting for the cohort this read judges. Read-only, and it changes
    # NO threshold and NO cohort membership: it exists because the platform's
    # ERASURE of our own posts is otherwise invisible to this leg in BOTH
    # directions, and neither direction is readable from `gate=`.
    #
    # Every count below is a post the platform has called terminal
    # (`insights_unavailable_at`, written by
    # Scheduling::Commands::CollectPostInsights when Instagram answers HTTP 400 /
    # code 100 for the media). Measured 2026-09-24: Instagram removed 36 of our 150
    # published posts, 25 of them in a single hour -- 24 had already been collected
    # and 11 were erased before their first collection, so those 11 can never enter
    # this cohort at all.
    #
    #   * `in_cohort` posts were erased AFTER collection. They still testify, but
    #     with the zeros they earned post-erasure, which drags the pillar leg DOWN
    #     -- a gate that fires on them is firing on an erasure, not on an audience.
    #   * `gone_uncollected` posts were erased BEFORE collection. They are silently
    #     absent from the cohort, so a removal wave shrinks the cohort toward
    #     :extend -- which reads as "not enough data yet" when the truth is that the
    #     platform deleted the evidence. The 10-05 read's cohort is the posts
    #     published 09-28..10-01, the same vintage the 09-24 wave wiped.
    def removal_accounting(inputs = nil)
      pool = post_intervention_posts(inputs)
      {
        rendered: pool.count,
        in_cohort: pool.where.not(insights_updated_at: nil)
                       .where.not(insights_unavailable_at: nil).count,
        gone_uncollected: pool.where(insights_updated_at: nil)
                              .where.not(insights_unavailable_at: nil).count
      }
    end

    # PURE: the erasure clause, or '' when nothing this leg reads is gone.
    def removal_clause(removal)
      in_cohort   = removal[:in_cohort].to_i
      uncollected = removal[:gone_uncollected].to_i
      return '' if (in_cohort + uncollected).zero?

      parts = []
      if in_cohort.positive?
        parts << "#{in_cohort} post(s) IN this cohort have since been REMOVED from the " \
                 'account, so they vote with the zeros they earned after the erasure, ' \
                 'not with an audience verdict'
      end
      if uncollected.positive?
        parts << "#{uncollected} post-intervention post(s) were removed BEFORE their " \
                 'insights were collected and can never enter the cohort at all, so a ' \
                 'cohort that shrinks this way is an ERASURE and not an absence of data ' \
                 '-- :extend on the count alone cannot tell the two apart'
      end
      " CONFOUND (platform removals): #{parts.join('; ')}."
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
