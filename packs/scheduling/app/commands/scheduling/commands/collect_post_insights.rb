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
      # query will re-select on every run forever.
      TERMINAL_API_CODES = [ 100 ].freeze

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
          unavailable << post.id if outcome == :unavailable
          next unless insights

          post.update!(insights)
          collected += 1
        end

        context.collected = collected
        context.pending = candidates.size
        context.unavailable = unavailable.size
        Rails.logger.info("CollectPostInsights: updated #{collected} of #{candidates.size} candidate posts")
        return if unavailable.empty?

        # A warning, not silence: these ids are re-requested on every run (the
        # query cannot tell a deleted media from a never-collected one), so the
        # budget they consume is visible and the ids are named for an operator.
        Rails.logger.warn(
          "CollectPostInsights: #{unavailable.size} of #{candidates.size} candidate post(s) can never be " \
          "refreshed (Instagram 400/code #{TERMINAL_API_CODES.join('/')}: media deleted or inaccessible): " \
          "ids=#{unavailable.join(',')} -- they re-enter every run because nothing records the terminal state"
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
      def posts_needing_insights
        Scheduling::Post
          .where(persona_id: Persona.find_by(name: "Sarah")&.id)
          .where(status: "posted")
          .where.not(provider_post_id: nil)
          .where("posted_at < ?", 24.hours.ago)
          .where("insights_updated_at IS NULL OR insights_updated_at < ?", 6.hours.ago)
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
          req.params["metric"] = "likes,comments,reach,saved,shares"
          req.params["access_token"] = token
        end

        return [ api_outcome(resp), nil ] unless resp.status == 200

        data = resp.body["data"] || []
        metrics = data.each_with_object({}) { |m, h| h[m["name"]] = m["values"].first&.dig("value") || 0 }

        likes    = metrics["likes"] || 0
        comments = metrics["comments"] || 0
        reach    = metrics["reach"] || 1
        saved    = (metrics["saved"] || 0) + (metrics["shares"] || 0)

        engagement = reach.positive? ? ((likes + comments + saved).to_f / reach * 100).round(2) : 0

        [ :ok, {
          likes_count: likes,
          comments_count: comments,
          reach: reach,
          saved_count: saved,
          engagement_rate: engagement,
          insights_updated_at: Time.current
        } ]
      rescue Faraday::Error => e
        Rails.logger.warn("CollectPostInsights API error for post #{post.id}: #{e.message}")
        [ :failed, nil ]
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
