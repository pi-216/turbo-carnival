# frozen_string_literal: true

module CaptionGeneration
  # Single source of truth for the caption model and its client timeout.
  #
  # Both caption paths (Generator - the text path every recent render takes,
  # and VisionGenerator - the image path) call Ollama on max395, and both were
  # hardcoded to gemma3:27b with a 180s client timeout.
  #
  # That model cannot be loaded there any more: its weights live on the NFS model
  # store (OLLAMA_MODELS=/mnt/nas-ai-models/ollama, measured ~40 MB/s direct
  # read), so a COLD load must read ~16.5 GB - longer than Ollama's ~300s
  # llama-server start timeout. Ollama kills the load and answers HTTP 500
  # "timed out waiting for llama-server to start"; the 180s client timeout fires
  # first, so the caller sees a timeout. Measured 2026-09-19 on max395: three
  # consecutive cold loads of gemma3:27b failed (two aborted by the client at
  # 180s, one by the server at 303s) while gemma3:4b cold-loaded and answered in
  # 147s.
  #
  # Every caller substitutes the placeholder caption 'Fresh look' when this
  # fails, so the degradation is invisible: it looks exactly like a healthy
  # pipeline. Keep these knobs env-overridable so the caption model can be moved
  # to one that fits the load budget without a code change:
  #
  #   CAPTION_MODEL=gemma3:4b CAPTION_TIMEOUT=180
  module ModelConfig
    DEFAULT_MODEL = 'gemma3:27b'
    DEFAULT_TIMEOUT = 180 # seconds

    module_function

    def model
      ENV.fetch('CAPTION_MODEL', DEFAULT_MODEL)
    end

    def timeout
      Integer(ENV.fetch('CAPTION_TIMEOUT', DEFAULT_TIMEOUT))
    rescue ArgumentError, TypeError
      DEFAULT_TIMEOUT
    end

    # The caller of either generator swaps in the placeholder caption on failure,
    # so the failure itself must be logged here or it is never seen anywhere.
    def log_failure(component:, error:, photo_id: nil)
      message = "[caption] #{component} failed model=#{model} timeout=#{timeout}s " \
                "photo=#{photo_id} #{error.class}: #{error.message}"
      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger.warn(message)
      else
        Kernel.warn(message)
      end
    end
  end
end
