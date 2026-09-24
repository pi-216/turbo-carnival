# frozen_string_literal: true

require 'faraday'
require 'json'

module Instagram
  class Client
    class Error < StandardError; end

    # Instagram answers the container status check with FINISHED and then rejects
    # the publish with 9007 / subcode 2207027 ("The media is not ready for
    # publishing, please wait for a moment"). Measured on post 333 (2026-09-20):
    # container create + status check + publish all finished in ~5s, so the
    # FINISHED answer is optimistic and the publish needs a moment -- publishing
    # immediately loses the slot permanently (3rd lifetime occurrence: posts 37,
    # 246, 333, each a lost slot AND a consumed photo). A retry is safe: 9007
    # means the container was NOT published, and containers are single-use, so a
    # retry can never produce a second post.
    class MediaNotReadyError < Error; end

    MEDIA_NOT_READY_CODES = [ 9007 ].freeze
    MEDIA_NOT_READY_SUBCODES = [ 2207027 ].freeze
    PUBLISH_ATTEMPTS = 4
    PUBLISH_RETRY_DELAY_S = 10

    # Reels need the strictest ready-check of any surface: a video container is
    # TRANSCODED, not fetched, so readiness takes minutes rather than the seconds
    # an image container needs. Bounded anyway -- 30 x 10s -- because an unbounded
    # wait inside the publisher would hold a release slot forever.
    REEL_READY_ATTEMPTS = 30
    REEL_READY_DELAY_S = 10

    # The two container types this account publishes. The only difference on the
    # API surface is the media_type discriminator and the asset parameter name
    # (`image_url` vs `video_url`); everything else -- caption, the AI
    # self-disclosure, the single-use container, the publish retry -- is shared,
    # which is why this is a parameter and not a second client.
    REEL_MEDIA_TYPE = 'REELS'

    BASE_URL = 'https://graph.facebook.com/v20.0'

    # Instagram's Content Publishing API takes a SELF-DISCLOSURE of AI usage on
    # the media container (`is_ai_generated`), which is one of the three paths
    # Meta documents for its "AI info" label (the others being their own
    # classifier and the IPTC/C2PA metadata in the bytes).
    #
    # `add-synthetic-provenance` requires viewer-facing disclosure "via the
    # platform's own label where the platform applies one" and carries it today
    # by embedding IPTC digitalSourceType=trainedAlgorithmicMedia in the served
    # bytes. That is an inference the platform has to make from our metadata;
    # this flag is the same disclosure stated outright in Meta's own record for
    # the post, and it is the half task 4.1 of that change left open.
    #
    # SET UNCONDITIONALLY, and that is an invariant rather than an assumption:
    # Scheduling::Commands::GeneratePublicPhotoUrl is the last step before
    # SendPostToInstagram on BOTH publishing rails and refuses to hand over an
    # asset whose synthetic marker is missing, so every asset that reaches this
    # client is a render of the persona.
    AI_DISCLOSURE_PARAM = 'is_ai_generated'

    def initialize
      @app_id = Rails.application.credentials.dig(:instagram, :app_id)
      @app_secret = Rails.application.credentials.dig(:instagram, :app_secret)
      @access_token = Rails.application.credentials.dig(:instagram, :access_token)
      @account_id = Rails.application.credentials.dig(:instagram, :account_id)

      raise ArgumentError, 'Instagram credentials are required' if [@app_id, @app_secret, @access_token,
                                                                    @account_id].any?(&:blank?)
    end

    def create_post(image_url:, caption:)
      creation_id = create_media_container(image_url, caption)
      wait_for_media_ready(creation_id)
      publish_when_ready(creation_id)
    rescue Faraday::Error => e
      raise Error, "Request failed: #{e.message}"
    end

    # Publish a REEL -- the DISCOVERY surface.
    #
    # WHY THIS EXISTS (ops decision, 2026-09-24). The account's own insights
    # answer `reach` with `breakdown=follow_type`, and the measured split is
    # FOLLOWER=6 / NON_FOLLOWER (absent, i.e. zero) with profile_views=0: the
    # platform states that nothing outside the follower list is shown these
    # posts. The growth thesis's mechanism is publish -> discovery -> follows, so
    # with no discovery step every content lever is inert by construction. Reels
    # are the one organic Instagram surface that distributes to non-followers,
    # and it publishes on the SAME account and API -- no credential, no platform
    # change -- so the pivot is a build rather than a credential ask.
    #
    # The asset is produced by Growth::ReelBuilder, which also embeds the IPTC
    # synthetic mark in the container, so the AI self-disclosure here and the
    # bytes' marker stay the still path's pairing.
    def create_reel(video_url:, caption:)
      creation_id = create_reel_container(video_url, caption)
      wait_for_media_ready(creation_id, max_attempts: REEL_READY_ATTEMPTS, delay_seconds: REEL_READY_DELAY_S)
      publish_when_ready(creation_id)
    rescue Faraday::Error => e
      raise Error, "Request failed: #{e.message}"
    end

    # WHERE the account's reach came from -- its own followers, or accounts that
    # do not follow it -- plus profile visits, the step between reach and a
    # follow.
    #
    # Why this exists (measured 2026-09-24): the pre-registered GO/PIVOT/KILL
    # gate names "distribution/reach" as its pivot candidate, but the only reach
    # this repo held was PER-POST (scheduling_posts.reach). Per-post reach cannot
    # separate "our followers see every post" from "strangers find us", and those
    # are different businesses. Instagram's account-level insights answer the
    # question directly: `GET /{account_id}/insights?metric=reach&period=day&
    # metric_type=total_value&breakdown=follow_type`. Measured live 2026-09-24:
    # reach=6 with `FOLLOWER=6` and NO `NON_FOLLOWER` result -- zero non-follower
    # reach, stated by the platform rather than inferred from a sum.
    #
    # Returns a hash with nil for anything the API did not answer.
    #
    # ABSENCE OF A BREAKDOWN VALUE IS A MEASURED ZERO, not an unknown: the API
    # returns only the dimension values that are non-zero, so a follow_type
    # breakdown that carries FOLLOWER and no NON_FOLLOWER means no non-follower
    # reach. What IS unknown is a response with no breakdown block at all -- that
    # keeps nil, so a shape change cannot manufacture a "zero discovery" verdict.
    # `reach_total` is recorded alongside so the two parts can always be checked
    # against the whole; a permanent 0 that never reconciles with the total is
    # how a silently broken breakdown would show itself.
    def reach_attribution
      reach = account_reach_breakdown
      reach.merge(profile_views: account_profile_views)
    end

    # Fetch the current follower count for the connected business account.
    # Graph API: GET /{account_id}?fields=followers_count
    def followers_count
      response = connection.get(@account_id) do |req|
        req.params['fields'] = 'followers_count'
        req.params['access_token'] = @access_token
      end

      body = handle_response(response)
      count = body['followers_count'] || body[:followers_count]
      raise Error, "Account response missing followers_count: #{body}" if count.nil?

      count.to_i
    rescue Faraday::Error => e
      raise Error, "Request failed: #{e.message}"
    end

    # Fetch how many media objects the account currently holds.
    # Graph API: GET /{account_id}?fields=media_count
    #
    # This is the only number that can separate a platform-side REMOVAL from our
    # own bookkeeping. `provider_post_id` is written once at publish time and
    # never re-read, so a post Instagram takes down keeps counting as published
    # in every local read (queue runway, acceptance counters, per-pillar
    # engagement) with nothing erroring. Publishing can only INCREASE
    # media_count, so a DECREASE across snapshots is removal stated by the
    # platform rather than inferred from our records.
    #
    # Returns nil when the API answers without the field (never measured) --
    # the same rule as the reach attribution: a failed or changed call must not
    # read as a measured zero.
    def media_count
      response = connection.get(@account_id) do |req|
        req.params['fields'] = 'media_count'
        req.params['access_token'] = @access_token
      end

      body = handle_response(response)
      count = body['media_count'] || body[:media_count]
      return nil if count.nil?

      count.to_i
    rescue Faraday::Error => e
      raise Error, "Request failed: #{e.message}"
    end

    private

    # -> { follower_reach:, non_follower_reach:, reach_total: }, each nil when
    # the API did not answer. Never raises: a missing measurement must not cost
    # the caller the follower count it came for.
    def account_reach_breakdown
      body = insights_metric('reach', breakdown: 'follow_type')
      node = Array(body['data'] || body[:data]).find { |d| d['name'] == 'reach' }
      return { follower_reach: nil, non_follower_reach: nil, reach_total: nil } unless node

      total = metric_total(node)
      breakdowns = (node['total_value'] || node[:total_value] || {})['breakdowns'] ||
                   (node['total_value'] || node[:total_value] || {})[:breakdowns]
      # No breakdown block at all == the metric answered without attribution.
      # UNKNOWN, not zero: see the note on #reach_attribution.
      return { follower_reach: nil, non_follower_reach: nil, reach_total: total } if breakdowns.blank?

      sums = {}
      Array(breakdowns).each do |b|
        Array(b['results'] || b[:results]).each do |r|
          sums[Array(r['dimension_values'] || r[:dimension_values]).first.to_s.upcase] = r['value'].to_i
        end
      end

      # A dimension the API omitted is a measured zero (it reports only non-zero
      # values); see the class note.
      {
        follower_reach: sums.fetch('FOLLOWER', 0),
        non_follower_reach: sums.fetch('NON_FOLLOWER', 0),
        reach_total: total || sums.values.sum
      }
    rescue Faraday::Error, Error => e
      Rails.logger.warn("Instagram::Client#reach_attribution: reach breakdown unavailable (#{e.message})")
      { follower_reach: nil, non_follower_reach: nil, reach_total: nil }
    end

    # -> Integer profile visits for the period, or nil when unanswered.
    def account_profile_views
      body = insights_metric('profile_views', breakdown: nil)
      node = Array(body['data'] || body[:data]).find { |d| d['name'] == 'profile_views' }
      node && metric_total(node)
    rescue Faraday::Error, Error => e
      Rails.logger.warn("Instagram::Client#reach_attribution: profile_views unavailable (#{e.message})")
      nil
    end

    def insights_metric(metric, breakdown:)
      response = connection.get("#{@account_id}/insights") do |req|
        req.params['metric'] = metric
        req.params['period'] = 'day'
        req.params['metric_type'] = 'total_value'
        req.params['breakdown'] = breakdown if breakdown
        req.params['access_token'] = @access_token
      end
      handle_response(response)
    end

    # total_value.value, tolerating the string/symbol key split Faraday's JSON
    # middleware can produce and a plain `value` shape.
    def metric_total(node)
      tv = node['total_value'] || node[:total_value] || node
      raw = tv.is_a?(Hash) ? (tv['value'] || tv[:value]) : tv
      raw.nil? ? nil : raw.to_i
    end

    def wait_for_media_ready(creation_id, max_attempts: 10, delay_seconds: 3)
      max_attempts.times do |attempt|
        response = connection.get(creation_id) do |req|
          req.params['fields'] = 'status_code'
          req.params['access_token'] = @access_token
        end

        body = handle_response(response)
        status_code = body['status_code'] || body[:status_code]

        return if status_code == 'FINISHED'
        raise Error, "Media processing failed with status_code=ERROR" if status_code == 'ERROR'

        sleep(delay_seconds) if attempt < max_attempts - 1
      end

      raise Error, 'Media not ready for publishing after waiting'
    end

    def connection
      Faraday.new(url: BASE_URL) do |conn|
        conn.request :url_encoded
        conn.response :json
        conn.adapter Faraday.default_adapter
      end
    end

    def handle_response(response)
      unless response.success?
        message = "API Error: #{response.status} - #{response.body}"
        raise MediaNotReadyError, message if media_not_ready?(response.body)

        raise Error, message
      end

      response.body
    end

    # Publish, tolerating the "not ready yet" answer Instagram gives right after
    # its own status check said FINISHED. Bounded: 4 attempts, 10s apart, and any
    # other error (or the last attempt) fails exactly as before.
    def publish_when_ready(creation_id)
      attempt = 0
      begin
        attempt += 1
        publish_media_container(creation_id)
      rescue MediaNotReadyError => e
        raise if attempt >= PUBLISH_ATTEMPTS

        Rails.logger.warn(
          "Instagram container #{creation_id} not ready to publish " \
          "(attempt #{attempt}/#{PUBLISH_ATTEMPTS}); retrying in #{PUBLISH_RETRY_DELAY_S}s: #{e.message}"
        )
        sleep(PUBLISH_RETRY_DELAY_S)
        retry
      end
    end

    def media_not_ready?(body)
      error = body.is_a?(Hash) ? (body['error'] || body[:error]) : nil
      return false unless error.is_a?(Hash)

      code = error['code'] || error[:code]
      subcode = error['error_subcode'] || error[:error_subcode]
      MEDIA_NOT_READY_CODES.include?(code.to_i) || MEDIA_NOT_READY_SUBCODES.include?(subcode.to_i)
    end

    # A parameter this account's API version does not know must never cost a
    # render a slot, so a failed attempt with the disclosure falls back to the
    # unflagged container -- byte-for-byte the pre-disclosure behaviour. The
    # second attempt raises the real error if there was one, so nothing is
    # masked; the cost of the fallback is at most one extra container request.
    def create_media_container(image_url, caption)
      create_container(image_url, caption, ai_disclosure: true)
    rescue Error => e
      Rails.logger.warn(
        "Instagram container create with #{AI_DISCLOSURE_PARAM}=true failed " \
        "(#{e.message}); retrying without the AI self-disclosure"
      )
      create_container(image_url, caption, ai_disclosure: false)
    end

    # Same disclosure fallback as the still path, on the video container. A
    # parameter this account's API version rejects must not cost the slot, and
    # the fallback costs at most one extra container request -- the bytes still
    # carry the IPTC mark either way.
    def create_reel_container(video_url, caption)
      create_container(video_url, caption, ai_disclosure: true, media_type: REEL_MEDIA_TYPE)
    rescue Error => e
      Rails.logger.warn(
        "Instagram REELS container create with #{AI_DISCLOSURE_PARAM}=true failed " \
        "(#{e.message}); retrying without the AI self-disclosure"
      )
      create_container(video_url, caption, ai_disclosure: false, media_type: REEL_MEDIA_TYPE)
    end

    # `media_type` is sent only when it differs from the default (an image
    # container is the absence of the parameter), so the still path's request is
    # byte-for-byte what it was before Reels existed.
    def create_container(asset_url, caption, ai_disclosure:, media_type: nil)
      response = connection.post("#{@account_id}/media") do |req|
        req.params[media_type ? 'video_url' : 'image_url'] = asset_url
        req.params['caption'] = caption
        req.params['media_type'] = media_type if media_type
        req.params[AI_DISCLOSURE_PARAM] = 'true' if ai_disclosure
        req.params['access_token'] = @access_token
      end
      handle_response(response)['id']
    end

    def publish_media_container(creation_id)
      response = connection.post("#{@account_id}/media_publish") do |req|
        req.params['creation_id'] = creation_id
        req.params['access_token'] = @access_token
      end
      handle_response(response)
    end
  end
end
