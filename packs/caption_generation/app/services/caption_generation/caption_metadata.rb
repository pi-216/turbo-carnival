# frozen_string_literal: true

module CaptionGeneration
  # What produced (or failed to produce) a caption, shaped for persistence on
  # scheduling_posts.caption_metadata.
  #
  # Both growth-harness producers (Growth::ContentGenerator, Growth::RenderSalvage)
  # substitute the placeholder caption 'Fresh look ✨' when the caption call fails,
  # and Scheduling::Post#caption is then the ONLY surviving evidence: the log line
  # ages out of the log and the caption text itself looks like a content choice.
  # That is how a 62% placeholder rate went unnoticed, and how a caption written by
  # the fallback model (see ModelConfig.resolve) is indistinguishable after the fact
  # from one written by the preferred model. Persist the choice and the failure
  # reason on the post so an ops probe can COUNT them instead of re-diagnosing from
  # scratch.
  module CaptionMetadata
    module_function

    # @param result [GLCommand::Context, nil] a PostAutomation::GenerateCaption
    #   result (responds to #success?, #caption_metadata, #errors) or nil when the
    #   captioner raised before returning one.
    # @param placeholder [Boolean] true when the caller shipped the placeholder
    # @return [Hash] always a Hash (jsonb column), never nil, never raising
    def for_result(result, placeholder: false)
      meta = base_metadata(result)
      meta[:placeholder] = true if placeholder
      unless success?(result)
        meta[:failed] = true
        meta[:error] = failure_message(result)
      end
      meta[:recorded_at] = Time.current.iso8601
      meta
    rescue StandardError
      { failed: true, error: 'caption metadata could not be recorded' }
    end

    # True only when the captioner returned a usable caption. Callers use this to
    # decide between the real caption and the placeholder.
    def success?(result)
      result.respond_to?(:success?) && result.success?
    rescue StandardError
      false
    end

    # The captioner's own metadata hash (model, model_selection, timeout, ...).
    def base_metadata(result)
      return {} if result.nil?

      value = result.respond_to?(:caption_metadata) ? result.caption_metadata : nil
      value.is_a?(Hash) ? value.dup : {}
    rescue StandardError
      {}
    end

    def failure_message(result)
      return 'captioner raised before returning a result' if result.nil?

      messages = result.respond_to?(:errors) ? Array(result.errors&.full_messages) : []
      return messages.join('; ') if messages.any?

      detail = result.respond_to?(:full_error_message) ? result.full_error_message.to_s : ''
      detail.presence || 'caption generation failed'
    rescue StandardError
      'caption generation failed'
    end
  end
end
