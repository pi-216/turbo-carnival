# frozen_string_literal: true

module Scheduling
  # The manual "post now" rail (Scheduling::PostsController#create_and_post_now).
  #
  # This class declared `optional caption_metadata: Hash`, which GLCommand does not
  # define (only `requires` exists on Callable/Chainable in gl_command 1.4.0), so
  # the class body raised NoMethodError on LOAD: every reference to
  # Scheduling::SchedulePost -- including the controller's -- failed with
  # `undefined method 'optional'`. Nothing in the test suite loaded it, so it was
  # invisible. The contract now declares only what the chain requires; an extra
  # `caption_metadata:` still reaches CreatePostRecord (which declares it optional
  # itself) through the chain's opts_hash.
  class SchedulePost < GLCommand::Chainable
    requires photo: ContentPillars::Photo, persona: Persona, caption: String
    allows caption_metadata: Hash
    returns post: Scheduling::Post

    chain Scheduling::Commands::CreatePostRecord,
          Scheduling::Commands::GeneratePublicPhotoUrl,
          Scheduling::Commands::SendPostToInstagram,
          Scheduling::Commands::UpdatePostWithInstagramId
  end
end
