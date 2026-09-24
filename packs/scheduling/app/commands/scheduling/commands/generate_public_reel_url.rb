# frozen_string_literal: true

module Scheduling
  module Commands
    # Resolves the URL Instagram will fetch for a REELS post -- the missing input
    # of Instagram::Client#create_reel.
    #
    # WHY THIS EXISTS (ops decision 2026-09-24). The pre-registered
    # GO/PIVOT/KILL gate names `distribution/reach` as its pivot candidate, and
    # the measured answer is unambiguous: the account's own insights report
    # FOLLOWER-only reach (NON_FOLLOWER absent) with profile_views=0, so nothing
    # outside the follower list is shown these posts. Reels are the one organic
    # surface with non-follower distribution, and #create_reel was built for it --
    # but a video container takes a `video_url:`, and NOTHING served a video:
    # MediaController#photo serves `image/png`. A built arm whose last step cannot
    # be called is not an arm, so this is the twin of GeneratePublicPhotoUrl for
    # the motion path.
    #
    # It is a FAIL-CLOSED gate for the same reason the photo path is: the URL is
    # a passthrough to `post.reel_path`, so the bytes Meta fetches are the bytes
    # checked here. A reel that carries no machine-readable synthetic mark must
    # not reach Instagram::Client#create_reel -- presenting synthetic media as
    # photography is the red line, and it is checked on the video's own bytes
    # (Iptc4xmpExt:DigitalSourceType, written into the MP4 container by
    # Growth::ReelBuilder) rather than on a flag we set alongside it.
    class GeneratePublicReelUrl < GLCommand::Callable
      requires post: Scheduling::Post
      returns public_reel_url: String

      def call
        path = post.reel_path.to_s

        if path.blank?
          stop_and_fail!('Post has no reel_path: this is not a REELS post, so there is no video to publish')
          return
        end

        unless File.file?(path)
          stop_and_fail!("Reel file is missing on disk: #{path}. Rebuilding the post's reel is required.")
          return
        end

        unless marked?(path)
          stop_and_fail!("Reel #{path} carries no machine-readable synthetic mark, so publishing it would " \
                         'present synthetic media as photography. Rebuild it with Growth::ReelBuilder, which ' \
                         'embeds the mark in the MP4 container.')
          return
        end

        if app_public_base.blank?
          stop_and_fail!('No public base URL configured (TURBO_CARNIVAL_PUBLIC_URL or app.public_url), so ' \
                         'Instagram could not fetch the reel')
          return
        end

        context.public_reel_url = "#{app_public_base}/media/reels/#{post.id}"
      end

      private

      # Read from the bytes, not from the builder's return value.
      #
      # The marker substring is the IPTC vocabulary both rails use, so the photo
      # marker's reader answers this question directly -- a second parser is a
      # second thing to drift. It returns false for an unreadable file, which the
      # call above has already rejected as missing.
      def marked?(path)
        ContentPillars::PhotoAssetMarker.marked?(path)
      end

      def app_public_base
        ENV['TURBO_CARNIVAL_PUBLIC_URL'].presence ||
          Rails.application.credentials.dig(:app, :public_url).to_s.presence
      end
    end
  end
end