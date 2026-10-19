# frozen_string_literal: true

module Scheduling
  module Commands
    class CreatePostRecord < GLCommand::Callable
      requires photo: ContentPillars::Photo, persona: Persona, caption: String
      allows caption_metadata: Hash
      returns post: Scheduling::Post

      def call
        context.post = Scheduling::Post.create!(
          photo: photo,
          persona: persona,
          caption: caption,
          caption_metadata: caption_metadata || {},
          status: 'draft'
        )
      end

      def rollback
        context.post&.destroy!
      end
    end
  end
end
