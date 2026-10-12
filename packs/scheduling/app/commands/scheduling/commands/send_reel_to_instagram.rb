# frozen_string_literal: true

module Scheduling
  module Commands
    # Publish a REELS post -- the twin of SendPostToInstagram for the motion path,
    # and the production caller Instagram::Client#create_reel was built for.
    #
    # WHY THIS EXISTS. The pre-registered GO/PIVOT/KILL gate names
    # `distribution/reach` as its pivot candidate, and the account's own insights
    # answered it unambiguously (measured 2026-09-24): FOLLOWER-only reach with
    # NO non-follower row and profile_views=0, i.e. nothing outside the follower
    # list is shown these posts. Reels are the one organic surface with
    # non-follower distribution and they publish on the SAME account and API, so
    # the pivot is a build. The asset step (Growth::ReelBuilder), the container
    # step (Instagram::Client#create_reel), the serving step
    # (MediaController#reel + GeneratePublicReelUrl) and the record
    # (scheduling_posts.reel_path) were all built and verified on 2026-09-24 --
    # but nothing in production CALLED the publish, so the arm was declared and
    # inert. The ops check keys on this call (bin/tc_ops.py check_reel_arm_stall
    # scans for `create_reel` outside specs), which is why this class is the arm
    # rather than a detail of it.
    #
    # It mirrors SendPostToInstagram deliberately: same GLCommand shape, same
    # single-use container, same error surfacing, same rollback warning. The
    # differences all live in the client (video_url + media_type=REELS and the
    # longer, bounded video ready-check) so the two rails cannot drift.
    class SendReelToInstagram < GLCommand::Callable
      requires :public_reel_url, :caption, :persona
      returns :instagram_post_id

      def call
        send_to_instagram!
      end

      private

      def send_to_instagram!
        response = create_instagram_reel
        extract_instagram_post_id(response)
      rescue Instagram::Client::Error => e
        stop_and_fail!("Failed to send reel to Instagram: #{e.message}")
      end

      def create_instagram_reel
        instagram_client = Instagram::Client.new
        instagram_client.create_reel(
          video_url: public_reel_url,
          caption: caption
        )
      end

      def extract_instagram_post_id(response)
        context.instagram_post_id = response['id'] || response[:id]
        stop_and_fail!('Instagram API did not return a reel ID') if context.instagram_post_id.blank?
      end

      # A reel container is single-use, so a published-but-unrecorded reel is the
      # one case a retry cannot fix -- say so rather than pretending the slot is
      # recoverable, exactly as the still path does.
      def rollback
        return if context.instagram_post_id.blank?

        Rails.logger.warn("Instagram reel #{context.instagram_post_id} was created but could not be published. Manual cleanup may be required.")
      end
    end
  end
end
