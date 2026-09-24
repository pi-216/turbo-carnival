# frozen_string_literal: true

require "net/http"
require "json"
require "base64"
require "uri"

module AI
  class GeminiClient
    DEFAULT_MODEL = "gemini-2.5-pro"  # Using paid Pro model
    API_BASE = "https://generativelanguage.googleapis.com/v1beta"

    def initialize(api_key: nil, model: DEFAULT_MODEL)
      @api_key = api_key || ENV["GEMINI_API_KEY"]
      @model = model
      raise ArgumentError, "GEMINI_API_KEY environment variable not set" unless @api_key
    end

    def generate(prompt, system: nil, temperature: 0.7, max_tokens: 2000, image_path: nil)
      contents = []

      if system
        contents << {
          role: "user",
          parts: [ { text: system } ]
        }
        contents << {
          role: "model",
          parts: [ { text: "Understood. I will follow these instructions." } ]
        }
      end

      # Build user message parts
      user_parts = []

      # Add image if provided
      if image_path && File.exist?(image_path)
        user_parts << build_image_part(image_path)
      end

      # Add text prompt
      user_parts << { text: prompt }

      contents << {
        role: "user",
        parts: user_parts
      }

      payload = {
        contents: contents,
        generationConfig: {
          temperature: temperature,
          maxOutputTokens: max_tokens
        }
      }

      uri = URI("#{API_BASE}/models/#{@model}:generateContent?key=#{@api_key}")

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = payload.to_json

      response = http.request(request)

      if response.is_a?(Net::HTTPSuccess)
        body = JSON.parse(response.body)

        # Log the response for debugging
        if body.dig("candidates", 0, "finishReason") == "MAX_TOKENS"
          Rails.logger.warn("Gemini hit MAX_TOKENS limit")
        end

        # Extract text from response
        text = body.dig("candidates", 0, "content", "parts", 0, "text")

        if text.nil? || text.empty?
          Rails.logger.error("Gemini returned empty response: #{body.to_json}")
          nil
        else
          text
        end
      else
        raise "Gemini API error: #{response.code} - #{response.body}"
      end
    end

    def generate_text(prompt, temperature: 0.7, max_tokens: 2000)
      generate(prompt, temperature: temperature, max_tokens: max_tokens)
    end

    def available?
      !@api_key.nil?
    rescue
      false
    end

    private

    def build_image_part(image_path)
      # Read and encode image
      image_data = File.binread(image_path)
      encoded_image = Base64.strict_encode64(image_data)

      # Determine MIME type
      mime_type = case File.extname(image_path).downcase
      when ".jpg", ".jpeg" then "image/jpeg"
      when ".png" then "image/png"
      when ".webp" then "image/webp"
      when ".heic" then "image/heic"
      when ".heif" then "image/heif"
      else "image/jpeg"
      end

      {
        inline_data: {
          mime_type: mime_type,
          data: encoded_image
        }
      }
    end
  end
end
