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

    private

    def wait_for_media_ready(creation_id)
      max_attempts = 10
      delay_seconds = 3

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

    def create_container(image_url, caption, ai_disclosure:)
      response = connection.post("#{@account_id}/media") do |req|
        req.params['image_url'] = image_url
        req.params['caption'] = caption
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
