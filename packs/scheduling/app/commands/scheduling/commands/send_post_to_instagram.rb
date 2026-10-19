# frozen_string_literal: true

module Scheduling
  module Commands
    class SendPostToInstagram < GLCommand::Callable
      requires :public_photo_url, :caption, :persona
      returns :instagram_post_id

      def call
        send_to_instagram!
      end

      private

      def send_to_instagram!
        response = create_instagram_post
        extract_instagram_post_id(response)
      rescue Instagram::Client::Error => e
        stop_and_fail!("Failed to send post to Instagram: #{e.message}")
      end

      def create_instagram_post
        instagram_client = Instagram::Client.new
        instagram_client.create_post(
          image_url: public_photo_url,
          caption: caption
        )
      end

      def extract_instagram_post_id(response)
        context.instagram_post_id = response['id'] || response[:id]
        stop_and_fail!('Instagram API did not return a post ID') if context.instagram_post_id.blank?
      end

      def rollback
        return if context.instagram_post_id.blank?

        Rails.logger.warn("Instagram post #{context.instagram_post_id} was created but could not be published. Manual cleanup may be required.")
      end
    end
  end
end
