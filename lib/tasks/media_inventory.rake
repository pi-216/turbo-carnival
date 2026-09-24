# frozen_string_literal: true

namespace :instagram do
  desc 'Read-only: list the account media ids and diff them against our published posts'
  task media_inventory: :environment do
    # WHY THIS EXISTS
    # `scheduling_posts.provider_post_id` is written ONCE at publish time and never
    # re-read, so a post Instagram removes keeps counting as published in every
    # local read (queue runway, acceptance counter, per-pillar engagement) with
    # nothing erroring. The only signal was a log line inside
    # Scheduling::Commands::CollectPostInsights, and it only fires for rows that
    # happen to be re-selected for insights -- so a removal was invisible.
    #
    # The account's own `media_count` (Growth::MetricsCollector#fetch_media_count,
    # hourly) is the cheap corroboration, but it is a STOCK: publishing adds ~3/day,
    # so a single removal can be masked by the same hour's additions. This task is
    # the SET instrument -- it lists what the account actually holds and names the
    # posts of OURS that are no longer in it.
    #
    # Measured 2026-09-24: 36 of the 150 posts this app published were absent from
    # the account (GET /{id} -> HTTP 400 code 100 subcode 33, while ids present in
    # the listing answer 200); 25 of them vanished in one burst the same day, and
    # the public profile (200 posts) agreed with the API's media_count. Nothing in
    # the app can delete media -- it only creates containers, publishes them and
    # reads insights -- so every one of those removals is platform-side.
    #
    # READ-ONLY: no writes, no publishing, no scheduler. Prints one machine-readable
    # line for bin/tc_ops.py and one human line.
    #
    #   bin/rails instagram:media_inventory
    require 'faraday'

    cred = Rails.application.credentials
    token = cred.dig(:instagram, :access_token)
    account = cred.dig(:instagram, :account_id)
    abort 'MEDIA_INVENTORY unreadable=credentials' if token.blank? || account.blank?

    conn = Faraday.new(url: Instagram::Client::BASE_URL) do |c|
      c.request :url_encoded
      c.response :json
      c.adapter Faraday.default_adapter
    end

    listed = []
    url = "#{account}/media"
    params = { fields: 'id,timestamp,media_type', limit: 100, access_token: token }
    12.times do # bounded: 1,200 media is far beyond any account this app runs
      resp = conn.get(url, params)
      # A non-200 is UNMEASURED, never "nothing missing": the caller must be able to
      # tell a broken read from a clean one, so this aborts rather than printing 0.
      abort "MEDIA_INVENTORY unreadable=http_#{resp.status}" unless resp.success?

      (resp.body['data'] || []).each { |m| listed << m['id'] }
      nxt = resp.body.dig('paging', 'next')
      break unless nxt

      params = URI.decode_www_form(URI.parse(nxt).query.to_s).to_h
    end

    ours = Scheduling::Post
           .where(status: 'posted')
           .where.not(provider_post_id: nil)
           .order(:posted_at)
           .pluck(:id, :provider_post_id, :posted_at)

    present = listed.to_set
    missing = ours.reject { |(_, pid, _)| present.include?(pid.to_s) }

    puts "MEDIA_INVENTORY listed=#{listed.size} ours=#{ours.size} missing=#{missing.size} " \
         "missing_posts=#{missing.map(&:first).join(',')} " \
         "missing_media=#{missing.map { |(_, pid, _)| pid }.join(',')}"
    puts "  platform holds #{listed.size} media; #{ours.size - missing.size} of our " \
         "#{ours.size} published post(s) are present, #{missing.size} are GONE"
    missing.each do |(id, pid, at)|
      puts "  GONE post=#{id} media=#{pid} posted_at=#{at&.utc&.iso8601}"
    end
  end
end
