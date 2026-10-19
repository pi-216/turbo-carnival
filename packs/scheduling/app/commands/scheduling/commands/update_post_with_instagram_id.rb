# frozen_string_literal: true

module Scheduling
  module Commands
    class UpdatePostWithInstagramId < GLCommand::Callable
      requires post: Scheduling::Post, instagram_post_id: String
      returns post: Scheduling::Post

      def call
        @original_status = post.status
        @original_provider_post_id = post.provider_post_id

        post.update!(provider_post_id: instagram_post_id)
        post.schedule!

        context.post = post
      end

      def rollback
        return unless post

        post.update!(
          status: @original_status,
          provider_post_id: @original_provider_post_id
        )
      end
    end
  end
end
