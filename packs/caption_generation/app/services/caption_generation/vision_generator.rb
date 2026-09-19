# frozen_string_literal: true

require 'base64'

module CaptionGeneration
  # Image path: sends the photo to a vision model. Note this path is only taken
  # when the photo has an ActiveStorage attachment (see
  # PostAutomation::GenerateCaption); renders imported by the growth harness are
  # path-only, so they take CaptionGeneration::Generator instead.
  class VisionGenerator
    def self.generate(photo:, persona:, content_pillar: nil)
      new(photo: photo, persona: persona, content_pillar: content_pillar).generate
    end

    def initialize(photo:, persona:, content_pillar: nil)
      @photo = photo
      @persona = persona
      @content_pillar = content_pillar
    end

    def generate
      raise ArgumentError, 'Persona caption_config is required' unless @persona.caption_config
      raise ArgumentError, 'Photo must have attached image' unless @photo.image.attached?

      # Get image as base64
      image_base64 = encode_image

      # Build vision prompt
      prompt = build_vision_prompt

      # Call Ollama with vision
      client = AI::OllamaClient.new(model: ModelConfig.model, timeout: ModelConfig.timeout)

      result = client.chat(
        messages: [
          {
            role: 'user',
            content: prompt,
            images: [image_base64]
          }
        ],
        temperature: 0.7
      )

      # Process the generated caption
      caption_text = result[:text]
      processed = PostProcessor.process(caption_text, @persona.caption_config)

      Result.new(
        text: processed[:text],
        metadata: build_metadata(processed, result),
        success: processed[:compliant]
      )
    rescue StandardError => e
      ModelConfig.log_failure(component: 'vision', error: e, photo_id: @photo&.id)
      Result.new(
        text: '',
        metadata: { error: e.message, vision: true,
                    model: ModelConfig.model, timeout: ModelConfig.timeout },
        success: false
      )
    end

    private

    def encode_image
      # Prefer the local/NAS file (no B2). Falls back to the ActiveStorage blob.
      local = @photo.servable_file_path
      data = if local
        File.binread(local)
      else
        @photo.image.download
      end

      Base64.strict_encode64(downscaled(data))
    end

    # Downscale before sending: gemma3 vision cost grows fast with image size.
    # Any comfy/flux output is far bigger than the ~768-1024px vision models need.
    MAX_DIMENSION = 1024
    MAX_PIXELS = MAX_DIMENSION * MAX_DIMENSION

    def downscaled(data)
      require 'mini_magick'
      image = MiniMagick::Image.read(data)
      pixels = image.width * image.height
      if pixels.nil? || pixels <= MAX_PIXELS # already small enough
        image.to_blob
      else
        image.resize("#{MAX_DIMENSION}x#{MAX_DIMENSION}>") # fit within max dim
        image.to_blob
      end
    rescue StandardError
      # If downscale fails (no imagemagick, odd format), send original
      data
    end

    def build_vision_prompt
      style = @persona.caption_config.style || 'casual'
      tone = @persona.caption_config.tone || 'friendly'
      voice = @persona.caption_config.voice || 'authentic'
      max_length = @persona.caption_config.max_length || 150

      pillar_context = if @content_pillar
        context = "\n\nContent Theme: #{@content_pillar.name}"
        if @content_pillar.ai_prompt.present?
          context += "\nGuidelines: #{@content_pillar.ai_prompt}"
        end
        context
      else
        ""
      end

      <<~PROMPT
        You are writing an Instagram caption for #{@persona.name}.

        Writing Style Guide:
        - Style: #{style}
        - Tone: #{tone}
        - Voice: #{voice}
        - Maximum length: #{max_length} words
        #{pillar_context}

        Instructions:
        1. Return ONLY the caption text
        2. Analyze the image carefully
        3. Write a caption that describes what you see
        4. Match the personality and style specified above
        5. Keep it under #{max_length} words
        6. Make it engaging and authentic
      PROMPT
    end

    def build_metadata(processed, ai_result)
      {
        model: ai_result[:model] || ModelConfig.model,
        requested_model: ModelConfig.model,
        timeout: ModelConfig.timeout,
        generator: 'vision',
        word_count: processed[:text].split.size,
        char_count: processed[:text].length,
        compliant: processed[:compliant],
        warnings: processed[:warnings] || []
      }
    end
  end
end
