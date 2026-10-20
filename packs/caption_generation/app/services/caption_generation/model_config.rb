# frozen_string_literal: true

module CaptionGeneration
  # Single source of truth for the vision-read and caption MODEL: the local
  # brain (PRD 0001), an OpenAI-compatible llama-server seat whose serving
  # location is DATA in config/autonomous/brain.yml (endpoint, alias, timeout) —
  # never hard-coded here.
  #
  # FOUNDERS DECISION (2026-10-19, ticket #103, PRD 0007 A4 + Q1/Q2): the brain
  # REPLACES Ollama as the pipeline's reader (age gate) and caption writer.
  # "We could replace ollama with the brain. It's a vision enabled model."
  #
  # Why Ollama went away from this path: the Ollama host is the same 4090 the
  # brain owns (23.6 of 24 GiB resident), so a cold gemma3 load there fails with
  # cudaMemGetInfo out-of-memory — measured 2026-10-19 on gemma3:4b. And max395
  # "is serving a huge model and is no longer available for serving" (founder,
  # 2026-10-19). A fallback to either host only exists while the brain is down,
  # at which point the read path has already degraded — so there is NO ladder.
  # The gemma3 models stay on disk for ad-hoc use; they are retired from this
  # resolution path, not deleted.
  #
  # DEGRADATION IS LOUD, BY CONSTRUCTION: when the brain is not answering,
  # resolve returns available: false and the reason 'brain_unavailable'.
  # Callers degrade to today's floor — the vision probe returns unreadable (the
  # age gate logs a warning and publishes unchanged, fail-open), and the caption
  # path ships the placeholder — but the REASON is recorded in the metadata and
  # logged here, so a dead brain can never read as a healthy pipeline. A true
  # always-available fallback is a second GPU host: a cost decision the founder
  # has not made, and it is not smuggled into this code.
  #
  # Env knobs (operational overrides, NOT the serving-home decision):
  #
  #   CAPTION_MODEL     brain model alias    (default: brain.yml serving.alias)
  #   CAPTION_ENDPOINT  brain endpoint       (default: brain.yml serving.endpoint)
  #   CAPTION_TIMEOUT   request timeout, s   (default: brain.yml serving.timeout_s)
  #
  # The old Ollama ladder's knobs (CAPTION_FALLBACK_MODEL, CAPTION_FALLBACK_
  # TIMEOUT, CAPTION_KEEP_ALIVE) are retired with the ladder: they would only
  # mislead an operator into thinking a fallback still exists.
  module ModelConfig
    # The serving home did not answer. A value, never a raise: callers degrade
    # to their floor (probe unreadable, caption placeholder) and log it. The
    # message IS the selection reason ('brain_unavailable'), so every log line
    # names the outage verbatim instead of a network error string.
    class UnavailableError < StandardError; end

    module_function

    # The seat's data, cached per process (AI::BrainClient reads brain.yml).
    def config
      load 'lib/ai/brain_client.rb' unless defined?(AI::BrainClient)
      AI::BrainClient.config
    end

    def model
      ENV.fetch('CAPTION_MODEL', config[:model])
    end

    def endpoint
      ENV.fetch('CAPTION_ENDPOINT', config[:endpoint])
    end

    def timeout
      positive_int(ENV.fetch('CAPTION_TIMEOUT', config[:timeout]), config[:timeout])
    end

    # The selection every read and caption call is built from:
    #
    #   { engine: :brain, client:, model:, endpoint:, timeout:, available:, reason: }
    #
    # available: false means the brain is not answering AND there is no fallback
    # to route to (the ladder is retired on purpose). Callers then degrade to
    # their floor value (probe unreadable, caption placeholder) and record
    # reason — they must NOT call anything.
    #
    # client: a ready AI::BrainClient built from exactly these values, so the
    # metadata's model/endpoint/timeout is provably the one that was called.
    def resolve
      load 'lib/ai/brain_client.rb' unless defined?(AI::BrainClient)
      client = AI::BrainClient.new(endpoint: endpoint, model: model, timeout: timeout)
      base = { engine: :brain, client: client, model: model, endpoint: endpoint, timeout: timeout }

      # A short fail-closed /health probe (BrainClient.available?, ~3s): the
      # brain is either answering or it is not; there is no cold-load state to
      # wait out, which is exactly what made the Ollama ladder exist.
      return base.merge(available: true, reason: 'brain') if client.available?

      log("[caption] brain serving home not answering (#{endpoint}) — this read/caption " \
          "degrades to its floor value (fail-open) and records reason 'brain_unavailable'")
      base.merge(available: false, reason: 'brain_unavailable')
    end

    # The caller of either generator swaps in the placeholder caption on
    # failure, so the failure itself must be logged here or it is never seen
    # anywhere.
    def log_failure(component:, error:, photo_id: nil)
      log("[caption] #{component} failed endpoint=#{endpoint} model=#{model} timeout=#{timeout}s " \
          "photo=#{photo_id} #{error.class}: #{error.message}")
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
