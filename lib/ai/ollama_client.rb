# frozen_string_literal: true

require "faraday"
require "json"

module AI
  class OllamaClient
    class Error < StandardError; end
    class TimeoutError < Error; end
    class ModelNotFoundError < Error; end

    ENDPOINT = "http://192.168.86.137:11434"
    DEFAULT_MODEL = "gemma3:27b"
    DEFAULT_TIMEOUT = 180 # Vision (image) inference on 27B can take 60-120s+

    # `keep_alive` (seconds, or -1 to pin forever) is sent with every request.
    # Without it Ollama unloads the model 5 minutes after the last call, so a
    # post created more than 5 minutes after the previous one pays a COLD load
    # again -- and on max395 a cold load is the failure this whole ladder exists
    # to route around. Sending it keeps the model the caption path actually uses
    # resident, so the next post answers in seconds.
    def initialize(endpoint: ENDPOINT, model: DEFAULT_MODEL, timeout: DEFAULT_TIMEOUT,
                   keep_alive: nil)
      @endpoint = endpoint
      @model = model
      @timeout = timeout
      @keep_alive = keep_alive
    end

    def generate(prompt:, system_prompt: nil, temperature: 0.7)
      full_prompt = build_full_prompt(prompt, system_prompt)

      response = connection.post("/api/generate") do |req|
        req.options.timeout = @timeout
        req.headers["Content-Type"] = "application/json"
        req.body = {
          model: @model,
          prompt: full_prompt,
          temperature: temperature,
          stream: false
        }.merge(keep_alive_body).to_json
      end

      handle_response(response)
    rescue Faraday::TimeoutError => e
      raise TimeoutError, "Ollama request timed out after #{@timeout}s. This may happen on first model load (30-60s). Try again."
    rescue Faraday::ConnectionFailed => e
      raise Error, "Cannot connect to Ollama at #{@endpoint}. Is it running?"
    rescue Faraday::Error => e
      raise Error, "Ollama request failed: #{e.message}"
    end

    def chat(messages:, temperature: 0.7, images: nil)
      body = {
        model: @model,
        messages: messages,
        temperature: temperature,
        stream: false
      }

      # Add images if provided (for vision models)
      body[:images] = images if images
      body.merge!(keep_alive_body)

      response = connection.post("/api/chat") do |req|
        req.options.timeout = @timeout
        req.headers["Content-Type"] = "application/json"
        req.body = body.to_json
      end

      handle_response(response)
    rescue Faraday::TimeoutError => e
      raise TimeoutError, "Ollama request timed out after #{@timeout}s. This may happen on first model load (30-60s). Try again."
    rescue Faraday::ConnectionFailed => e
      raise Error, "Cannot connect to Ollama at #{@endpoint}. Is it running?"
    rescue Faraday::Error => e
      raise Error, "Ollama request failed: #{e.message}"
    end

    def list_models
      response = connection.get("/api/tags")
      JSON.parse(response.body)
    rescue Faraday::Error => e
      raise Error, "Failed to list models: #{e.message}"
    end

    def model_available?
      models = list_models
      models["models"]&.any? { |m| m["name"].start_with?(@model) }
    rescue Error
      false
    end

    # Names of the models currently RESIDENT in Ollama's memory (/api/ps).
    #
    # A resident model answers in seconds; one that is not has to be read from
    # disk first. On max395 the model store is NFS (~40 MB/s), so a 27B cold
    # load cannot finish inside Ollama's ~300s llama-server start timeout.
    # Callers use this to choose a model that can actually answer rather than
    # waiting out the full client timeout and failing.
    #
    # Bounded timeouts on purpose: this runs inside the growth tick's caption
    # path, and an unresponsive Ollama must not be able to hang the tick.
    def loaded_models
      response = connection.get("/api/ps") do |req|
        req.options.open_timeout = 5
        req.options.timeout = 10
      end
      parsed = JSON.parse(response.body)
      Array(parsed["models"]).filter_map { |m| m["name"] || m["model"] }.reject(&:empty?)
    rescue Faraday::Error => e
      raise Error, "Failed to list loaded models: #{e.message}"
    end

    private

    # {} when no keep_alive was configured, so the request body is byte-identical
    # to what it was before this option existed.
    def keep_alive_body
      @keep_alive.nil? ? {} : { keep_alive: @keep_alive }
    end

    def connection
      Faraday.new(url: @endpoint) do |conn|
        conn.request :url_encoded
        conn.adapter Faraday.default_adapter
      end
    end

    def build_full_prompt(prompt, system_prompt)
      if system_prompt
        "#{system_prompt}\n\n#{prompt}"
      else
        prompt
      end
    end

    def handle_response(response)
      unless response.success?
        error_body = JSON.parse(response.body) rescue { "error" => response.body }
        raise Error, "Ollama API error: #{error_body['error'] || response.status}"
      end

      parsed = JSON.parse(response.body)

      # Extract text from response (different endpoints have different structures)
      text = parsed["response"] || parsed.dig("message", "content")

      raise Error, "No response text from Ollama" if text.nil? || text.empty?

      {
        text: text,
        model: parsed["model"],
        done: parsed["done"],
        metadata: parsed
      }
    end
  end
end
