# frozen_string_literal: true

module CaptionGeneration
  # Single source of truth for the caption model, its fallback, and the client
  # timeouts. Both caption paths (Generator - the text path every recent render
  # takes, and VisionGenerator - the image path) call Ollama on max395, and both
  # were hardcoded to gemma3:27b with a 180s client timeout.
  #
  # That model cannot be COLD-loaded there: its weights live on the NFS model
  # store (OLLAMA_MODELS=/mnt/nas-ai-models/ollama, measured ~40 MB/s direct
  # read), so a cold load must read ~16.5 GB - longer than Ollama's ~300s
  # llama-server start timeout. Ollama kills the load and answers HTTP 500
  # "timed out waiting for llama-server to start"; the 180s client timeout fires
  # first, so the caller sees a timeout. Measured 2026-09-19 on max395: three
  # consecutive cold loads of gemma3:27b failed (two aborted by the client at
  # 180s, one by the server at 303s) while gemma3:4b cold-loaded and answered in
  # 147s.
  #
  # Every caller substitutes the placeholder caption 'Fresh look' when this
  # fails, so the degradation is invisible: it looks exactly like a healthy
  # pipeline. Waiting out the dead 27B and THEN shipping a placeholder is the
  # worst of both - the tick pays the full timeout and the post still ships junk.
  #
  # So: ask Ollama what is RESIDENT (/api/ps) and call that. The 27B is used
  # whenever it is warm (it is the better writer and answers in seconds then);
  # when it is not, the fallback model - which fits the load budget - is used
  # instead of the placeholder. Env-overridable so the choice can be changed
  # without a code change:
  #
  #   CAPTION_MODEL=gemma3:4b CAPTION_TIMEOUT=300
  #   CAPTION_FALLBACK_MODEL=gemma3:4b   (empty string disables the ladder)
  module ModelConfig
    DEFAULT_MODEL = 'gemma3:27b'
    DEFAULT_FALLBACK_MODEL = 'gemma3:4b'
    DEFAULT_TIMEOUT = 180 # seconds; enough only for an already-resident model
    # A model that has to cold-load pays the disk read inside its own budget.
    DEFAULT_FALLBACK_TIMEOUT = 300
    # Seconds to keep the model the caption path used resident in Ollama.
    # Ollama's own default is 300s, which is shorter than the gap between two
    # posts, so every post paid a cold load. 0 (or a blank value) restores
    # Ollama's default behaviour.
    DEFAULT_KEEP_ALIVE = 6 * 60 * 60

    module_function

    def model
      ENV.fetch('CAPTION_MODEL', DEFAULT_MODEL)
    end

    # nil disables the ladder (an empty CAPTION_FALLBACK_MODEL means "preferred
    # model or nothing").
    def fallback_model
      value = ENV.fetch('CAPTION_FALLBACK_MODEL', DEFAULT_FALLBACK_MODEL).to_s.strip
      value.empty? ? nil : value
    end

    def timeout
      positive_int(ENV.fetch('CAPTION_TIMEOUT', DEFAULT_TIMEOUT), DEFAULT_TIMEOUT)
    end

    def fallback_timeout
      positive_int(ENV.fetch('CAPTION_FALLBACK_TIMEOUT', DEFAULT_FALLBACK_TIMEOUT),
                   DEFAULT_FALLBACK_TIMEOUT)
    end

    # Seconds to keep the chosen model resident (-1 pins it indefinitely).
    # nil means "send nothing", i.e. Ollama's own 300s default.
    def keep_alive
      raw = ENV.fetch('CAPTION_KEEP_ALIVE', DEFAULT_KEEP_ALIVE).to_s.strip
      return nil if raw.empty?

      parsed = Integer(raw)
      parsed.zero? ? nil : parsed
    rescue ArgumentError, TypeError
      DEFAULT_KEEP_ALIVE
    end

    # Choose the model to call and the timeout that belongs with it.
    #
    # @return [Hash] { model:, timeout:, reason: } - reason is recorded in the
    #   caption metadata so a degraded caption is visible after the fact.
    def resolve
      preferred = model
      fallback = fallback_model
      if fallback.nil? || fallback == preferred
        return selection(preferred, timeout, 'no_fallback_configured')
      end

      resident = resident_models
      # Probe failed: we cannot tell, so behave exactly as before the ladder.
      return selection(preferred, timeout, 'resident_check_unavailable') if resident.nil?
      return selection(preferred, timeout, 'preferred_resident') if resident?(resident, preferred)

      choice = selection(fallback, fallback_timeout, "preferred_not_resident(#{preferred})")
      log_fallback(choice, preferred)
      choice
    end

    # Names of the models Ollama currently holds in memory, or nil when the
    # probe itself failed (the caller then keeps the preferred model).
    def resident_models
      load 'lib/ai/ollama_client.rb' unless defined?(AI::OllamaClient)
      AI::OllamaClient.new(model: model).loaded_models
    rescue StandardError => e
      log("/api/ps probe failed: #{e.class}: #{e.message}")
      nil
    end

    # Ollama reports names with their tag ('gemma3:27b'); a quantised variant of
    # the same tag ('gemma3:27b-q4_K_M') still means the family is resident.
    def resident?(resident_names, wanted)
      Array(resident_names).any? do |name|
        name == wanted || name.start_with?("#{wanted}-")
      end
    end

    # The caller of either generator swaps in the placeholder caption on failure,
    # so the failure itself must be logged here or it is never seen anywhere.
    def log_failure(component:, error:, photo_id: nil)
      log("[caption] #{component} failed model=#{model} timeout=#{timeout}s " \
          "photo=#{photo_id} #{error.class}: #{error.message}")
    end

    def selection(model_name, timeout_seconds, reason)
      { model: model_name, timeout: timeout_seconds, reason: reason, keep_alive: keep_alive }
    end

    def log_fallback(choice, preferred)
      log("[caption] #{preferred} is not resident; using #{choice[:model]} " \
          "(timeout #{choice[:timeout]}s) instead of shipping the placeholder caption")
    end

    def log(message)
      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger.warn(message)
      else
        Kernel.warn(message)
      end
    end

    def positive_int(value, default)
      parsed = Integer(value)
      parsed.positive? ? parsed : default
    rescue ArgumentError, TypeError
      default
    end
  end
end
