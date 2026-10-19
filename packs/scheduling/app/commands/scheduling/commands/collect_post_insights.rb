# frozen_string_literal: true

module Scheduling
  module Commands
    class CollectPostInsights < GLCommand::Callable
      BASE_URL = "https://graph.facebook.com/v20.0"

      # HTTP 400 with Graph error code 100 on a media node means the object is
      # gone or not accessible with this token, so retrying can never succeed.
      # Measured 2026-09-20: ids 133-143 answer "(#100) Tried accessing
      # nonexisting field (insights)" and id 148 "Object with ID ... does not
      # exist, cannot be loaded due to missing permissions" -- 11 posts the
      # query re-selected on every run. Since 2026-09-22 that verdict is RECORDED
      # (insights_unavailable_at), so a terminal row stops consuming a slot until
      # the retry window below elapses.
      TERMINAL_API_CODES = [ 100 ].freeze

      # How long a row the API called terminal waits before it is asked again.
      # Not "never": code 100 covers a media that is gone AND one this token
      # cannot read, so a token/permission change must be able to recover a row.
      # The cost of the backoff is one wasted call per dead media per window
      # (11 calls/30d) against 11 calls on EVERY run (measured: 55 runs' worth of
      # warnings in the dev log) -- and 44% of the 25-row per-run budget.
      INSIGHTS_RETRY_AFTER = 30.days

      # `views` is Meta's promoted primary metric (it replaced impressions/plays) and it
      # answers for EVERY media product type, so it rides in the primary call.
      #
      # The stills-only metrics do NOT, and that is a measured trap rather than a
      # preference: on 2026-10-19 the account's reel answered
      #   400 code 100 "The Media Insights API does not support the follows,
      #   profile_visits metric for this media product type"
      # and in the same probe ONE unsupported metric failed the WHOLE request
      # (`...shares,views,follows,profile_visits` -> 400 where `...shares,views` -> 200).
      # Asking for all three together would therefore lose `reach` on every reel -- and
      # because code 100 is ALSO this command's terminal verdict, it would have recorded
      # every reel as permanently uncollectable and stopped refreshing it forever.
      PRIMARY_METRICS = "likes,comments,reach,saved,shares,views"
      STILLS_ONLY_METRICS = "follows,profile_visits"

      # The counts the caller needs to tell "nothing to do" from "the API failed":
      # a run with candidates but zero refreshes is a failure, not a no-op.
      # `unavailable` is the third outcome -- candidates the API will never serve
      # -- so a refresh count below the candidate count is attributable instead of
      # reading as an unexplained shortfall. Before this, every non-200 returned
      # nil silently (no log line at all) and the publisher printed "refreshed 14
      # of 25" with no cause for the other 11.
      returns :collected, :pending, :unavailable

      def call
        # .to_a, NOT find_each: find_in_batches reorders by primary key and
        # overrides the LIMIT, so the ORDER BY below -- the fix for "the same 25
        # oldest rows re-refreshed forever" -- was silently discarded (proved by
        # spec/tasks/collect_insights_spec.rb, which caught three already-collected
        # rows being refreshed instead of never-collected ones). The query is
        # capped at 25 rows, so loading them is free.
        candidates = posts_needing_insights.to_a
        collected = 0
        unavailable = []

        candidates.each do |post|
          outcome, insights = fetch_insights(post)
          if outcome == :unavailable
            unavailable << post.id
            # Record the verdict, so this row stops re-entering the selection
            # every run (see INSIGHTS_RETRY_AFTER). update_columns, not update!:
            # a terminal row can be old and carry a nil scheduled_at, and a
            # validation failure here would abort the whole collection run --
            # the marker must never cost the other 14 candidates their refresh.
            post.update_columns(insights_unavailable_at: Time.current)
          end
          next unless insights

          post.update!(insights)
          collected += 1
        end

        context.collected = collected
        context.pending = candidates.size
        context.unavailable = unavailable.size
        Rails.logger.info("CollectPostInsights: updated #{collected} of #{candidates.size} candidate posts")
        return if unavailable.empty?

        # A warning, not silence: these ids are named for an operator. They no
        # longer re-enter every run -- the verdict is recorded on
        # insights_unavailable_at and the selection skips a marked row for
        # INSIGHTS_RETRY_AFTER -- so this line fires once per terminal media per
        # retry window instead of once per run.
        Rails.logger.warn(
          "CollectPostInsights: #{unavailable.size} of #{candidates.size} candidate post(s) can never be " \
          "refreshed (Instagram 400/code #{TERMINAL_API_CODES.join('/')}: media deleted or inaccessible): " \
          "ids=#{unavailable.join(',')} -- recorded on insights_unavailable_at, not re-selected until " \
          "#{INSIGHTS_RETRY_AFTER.inspect} has passed"
        )
      end

      private

      # ORDER BY is load-bearing, not cosmetic. Without it Postgres returns rows in
      # physical order, so limit(25) re-refreshed the same handful of OLDEST rows on
      # every run and never reached the posts that have no insights at all --
      # measured 2026-09-20: 107 posted items with a provider id and NULL insights
      # (newest id 327), while ids 29-57 were re-collected, i.e. the newest write
      # was 2026-05-27. Never-collected first, then newest first: the recent posts
      # are the ones Growth::WeeklyReview reads for per-pillar engagement.
      #
      # The insights_unavailable_at filter is the second half of that fix. Rows the
      # API has already called terminal are "never collected" by definition, so
      # they sorted to the FRONT of this selection and spent 11 of its 25 slots on
      # calls that cannot succeed (measured 2026-09-22: ids 133-143 + 148, on every
      # run, 55 runs' worth of warnings in the dev log). Marked rows are skipped
      # until the retry window passes; nothing is excluded permanently.
      def posts_needing_insights
        Scheduling::Post
          .where(persona_id: Persona.find_by(name: "Sarah")&.id)
          .where(status: "posted")
          .where.not(provider_post_id: nil)
          .where("posted_at < ?", 24.hours.ago)
          .where("insights_updated_at IS NULL OR insights_updated_at < ?", 6.hours.ago)
          .where("insights_unavailable_at IS NULL OR insights_unavailable_at < ?", INSIGHTS_RETRY_AFTER.ago)
          .order(Arel.sql("insights_updated_at IS NULL DESC, posted_at DESC"))
          .limit(25) # Instagram rate limit: 200 calls/hour
      end

      # -> [outcome, attributes]. outcome is :ok, :unavailable (terminal, never
      # retryable), :failed (transient) or :skipped (nothing to ask about);
      # attributes is nil unless the API answered 200.
      def fetch_insights(post)
        token = Rails.application.credentials.dig(:instagram, :access_token)
        media_id = post.provider_post_id

        return [ :skipped, nil ] unless media_id && token

        conn = Faraday.new(url: BASE_URL) { |f| f.request :url_encoded; f.response :json }

        resp = conn.get("#{media_id}/insights") do |req|
          req.params["metric"] = PRIMARY_METRICS
          req.params["access_token"] = token
        end

        return [ api_outcome(resp), nil ] unless resp.status == 200

        metrics = parse_metrics(resp.body["data"])

        # Absent means zero for these three: they answer for every media product type,
        # so the API omitting one is a real 0. That is deliberately NOT true of `views`
        # or of the stills-only metrics -- see parse_metrics.
        likes    = metrics["likes"] || 0
        comments = metrics["comments"] || 0
        # nil == the API did not report reach. Recorded as UNKNOWN, never as a
        # number: the previous `|| 1` fabricated a denominator, and the growth
        # review's per-pillar engagement (likes+comments+saved)/reach -- the
        # number the pre-registered 3% criterion is read from -- is computed off
        # it. At the reach this account actually sees (median ~3) a fabricated 1
        # both understates reach and inflates the rate. Measured 2026-09-22: 8 of
        # 129 collected rows sit at reach==1 and are indistinguishable from real
        # 1s, which is exactly why the default cannot be a number.
        reach    = metrics["reach"]
        saved    = (metrics["saved"] || 0) + (metrics["shares"] || 0)
        # nil, NOT 0. `views` answers for every media product type, but an absent key
        # still means "the API did not report it", and a stored 0 there would be a
        # fabricated measurement -- the red line of #39.
        views    = metrics["views"]

        # FEED-only metrics, in their own call on purpose (see PRIMARY_METRICS). A reel
        # the repo already knows about is not asked at all, which saves the call; an
        # unmarked reel is asked and refused, and fetch_stills_only handles that
        # refusal so it can never become a terminal verdict.
        stills = post.reel_path.blank? ? fetch_stills_only(conn, media_id, token, post) : {}

        if reach.nil?
          Rails.logger.warn(
            "CollectPostInsights: post #{post.id} returned no `reach` metric " \
            "(metrics=#{metrics.keys.sort.join(',')}) -- recorded nil, not a default"
          )
        end

        engagement = reach.to_i.positive? ? ((likes + comments + saved).to_f / reach * 100).round(2) : 0

        [ :ok, {
          likes_count: likes,
          comments_count: comments,
          reach: reach,
          saved_count: saved,
          views: views,
          follows: stills["follows"],
          profile_visits: stills["profile_visits"],
          engagement_rate: engagement,
          insights_updated_at: Time.current
        } ]
      rescue Faraday::Error => e
        Rails.logger.warn("CollectPostInsights API error for post #{post.id}: #{e.message}")
        [ :failed, nil ]
      end

      # No `|| 0` here, and that is the whole point. A metric the API did not report must
      # stay ABSENT so the caller decides what absence means: for likes/comments/saved it
      # means zero (they answer for every media), but for `views` and the stills-only
      # metrics an absent key can mean "not applicable to this media product type", and a
      # stored 0 there would be a fabricated measurement (#39's red line).
      def parse_metrics(data)
        Array(data).each_with_object({}) { |m, h| h[m["name"]] = m["values"].first&.dig("value") }
      end

      # `follows` and `profile_visits` answer only for FEED media. Measured 2026-10-19
      # against the account's reel: 400 / code 100, "The Media Insights API does not
      # support the follows, profile_visits metric for this media product type".
      #
      # A refusal here is NOT the terminal verdict. `api_outcome` maps code 100 to
      # :unavailable, which RECORDS insights_unavailable_at and stops the row being
      # refreshed -- routing this call through it would mark every reel permanently
      # uncollectable. A refusal means "not applicable", so the answer is nil (unknown),
      # printed rather than swallowed, and the primary metrics that DID arrive are kept.
      def fetch_stills_only(conn, media_id, token, post)
        resp = conn.get("#{media_id}/insights") do |req|
          req.params["metric"] = STILLS_ONLY_METRICS
          req.params["access_token"] = token
        end

        unless resp.status == 200
          error = resp.body.is_a?(Hash) ? resp.body["error"] : nil
          code = error.is_a?(Hash) ? error["code"] : nil
          Rails.logger.info(
            "CollectPostInsights: post #{post.id} has no #{STILLS_ONLY_METRICS} " \
            "(HTTP #{resp.status}, code #{code.inspect}) -- recorded nil, not 0"
          )
          return {}
        end

        parse_metrics(resp.body["data"])
      rescue Faraday::Error => e
        # Transient, and it must not turn the post into a :failed row: the primary
        # metrics are already in hand and discarding them would cost real data for a
        # secondary metric.
        Rails.logger.warn("CollectPostInsights stills-only call failed for post #{post.id}: #{e.message}")
        {}
      end

      # The Graph error body is the only place the reason lives, so it is logged
      # rather than swallowed: a non-200 used to return nil with no trace.
      def api_outcome(resp)
        error = resp.body.is_a?(Hash) ? resp.body["error"] : nil
        code = error.is_a?(Hash) ? error["code"] : nil
        message = error.is_a?(Hash) ? error["message"] : resp.body.to_s[0, 200]
        Rails.logger.warn(
          "CollectPostInsights: media returned HTTP #{resp.status} (code=#{code.inspect}): #{message}"
        )
        TERMINAL_API_CODES.include?(code) ? :unavailable : :failed
      end
    end
  end
end
