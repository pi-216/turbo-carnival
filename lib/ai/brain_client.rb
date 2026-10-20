# frozen_string_literal: true

require "faraday"
require "json"
require "yaml"
require "date"

module AI
  # OpenAI-compatible client for the LOCAL UNCENSORED BRAIN (PRD 0001), served by
  # llama.cpp's `llama-server`. The planner roles talk to THIS instead of a hosted,
  # safety-tuned model, so a legal in-lane brief is planned without hedging
  # (ticket #27, W1.1).
  #
  # Endpoint and model alias are DATA from config/autonomous/brain.yml
  # (`serving.*`) — the seat's location is recorded in one place (ticket #26),
  # never hard-coded here.
  #
  # `available?` is a short, fail-closed probe: the planner must be able to fall
  # back rather than hang a tick on an absent brain. `generate` takes the same
  # (prompt, system:, temperature:, max_tokens:) shape as AI::GeminiClient and
  # AI::OllamaClient so a role can swap clients without changing its own code.
  #
  # VISION (ticket #103): `chat` also takes `images:`, an array of base64 image
  # bytes. They are attached to the user message as OpenAI-compatible
  # `image_url` content parts — the same wire shape every multimodal
  # OpenAI-compatible endpoint uses, and what llama-server's mmproj
  # (the HauhauCS projector, 1024 image tokens) decodes. The bytes' format is
  # sniffed by the image decoder; the encoder (CaptionGeneration::ImageEncoder)
  # normalises to JPEG so the data-URL label is true, not a guess.
  class BrainClient
    class Error < StandardError; end

    DEFAULT_ENDPOINT = "http://127.0.0.1:8080"
    DEFAULT_MODEL = "brain"
    DEFAULT_TIMEOUT = 120
    PROBE_TIMEOUT = 3

    def initialize(endpoint: nil, model: nil, timeout: nil)
      cfg = self.class.config
      @endpoint = endpoint || cfg[:endpoint]
      @model = model || cfg[:model]
      @timeout = timeout || cfg[:timeout]
    end

    # Serving location read from the seat's data file (cached per process).
    def self.config
      @config ||= begin
        file = Rails.root.join("config/autonomous/brain.yml")
        serving = (YAML.safe_load(File.read(file), permitted_classes: [ Date, Time ], aliases: true) || {})["serving"] || {}
        {
          endpoint: (serving["endpoint"] || DEFAULT_ENDPOINT).to_s,
          model: (serving["alias"] || DEFAULT_MODEL).to_s,
          timeout: (serving["timeout_s"] || DEFAULT_TIMEOUT).to_i
        }
      rescue StandardError
        { endpoint: DEFAULT_ENDPOINT, model: DEFAULT_MODEL, timeout: DEFAULT_TIMEOUT }
      end
    end

    # True only when the brain answers /health. Any error (down, timeout, DNS)
    # is false — callers fall back, they never block on this.
    def available?
      resp = Faraday.new(url: @endpoint) { |c| c.adapter Faraday.default_adapter }.get("/health") do |req|
        req.options.open_timeout = PROBE_TIMEOUT
        req.options.timeout = PROBE_TIMEOUT
      end
      resp.success?
    rescue StandardError
      false
    end

    def generate(prompt, system: nil, temperature: 0.7, max_tokens: 2000)
      messages = []
      messages << { role: "system", content: system } if system
      messages << { role: "user", content: prompt }
      chat(messages: messages, temperature: temperature, max_tokens: max_tokens)[:text]
    end

    def chat(messages:, temperature: 0.7, max_tokens: nil, thinking: false, images: nil)
      body = {
        model: @model,
        messages: with_images(messages, images),
        temperature: temperature,
        stream: false,
        # llama-server (OpenAI-compatible) puts a reasoning model's chain-of-thought
        # in `reasoning_content` and can leave `content` EMPTY when max_tokens is
        # spent on thinking. A planning role wants the answer, not the trace, so
        # thinking is off by default — measured: content present and immediate with
        # enable_thinking=false, empty at the same budget without it.
        chat_template_kwargs: { enable_thinking: thinking }
      }
      body[:max_tokens] = max_tokens if max_tokens

      response = connection.post("/v1/chat/completions") do |req|
        req.options.timeout = @timeout
        req.headers["Content-Type"] = "application/json"
        req.body = body.to_json
      end

      handle_response(response)
    rescue Faraday::Error => e
      raise Error, "brain request failed (#{@endpoint}): #{e.message}"
    end

    private

    # Attach base64 images to the FIRST user message as OpenAI-compatible
    # content parts, leaving every other message (and a call with no images)
    # byte-identical to before. The text part keeps the original content, so a
    # vision prompt is the same prompt plus its pictures — not a different one.
    #
    # @return [Array<Hash>] the messages with the user message's content
    #   replaced by [text part, image_url part, ...]
    def with_images(messages, images)
      image_urls = Array(images).compact.map { |b64| "data:image/jpeg;base64,#{b64}" }
      return messages if image_urls.empty?

      attached = false
      messages.map do |msg|
        next msg if attached || msg[:role] != "user"

        attached = true
        parts = [ { type: "text", text: msg[:content] } ]
        parts += image_urls.map { |url| { type: "image_url", image_url: { url: url } } }
        msg.merge(content: parts)
      end
    end

    def connection
      Faraday.new(url: @endpoint) do |conn|
        conn.request :url_encoded
        conn.adapter Faraday.default_adapter
      end
    end

    def handle_response(response)
      unless response.success?
        error = begin
          JSON.parse(response.body)["error"]
        rescue StandardError
          response.body
        end
        raise Error, "brain API error: #{error || response.status}"
      end

      parsed = JSON.parse(response.body)
      message = parsed.dig("choices", 0, "message") || {}
      # llama-server puts the answer in `content`. A thinking model may ALSO carry
      # `reasoning_content`; that is not the answer and must not be returned as one.
      text = message["content"].to_s.strip
      raise Error, "empty response from brain" if text.empty?

      { text: text, model: parsed["model"], metadata: parsed }
    end
  end
end
