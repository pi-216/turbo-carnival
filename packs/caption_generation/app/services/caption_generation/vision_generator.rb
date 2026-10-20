# frozen_string_literal: true

require 'base64'

module CaptionGeneration
  # Image path: sends the photo to a vision model. Note this path is only TAKEN
  # when the caller routes a photo here (see PostAutomation::GenerateCaption:
  # it branches on readable bytes); this class itself needs no attachment --
  # encode_image prefers the photo's local/NAS file -- so routing path-only
  # renders here is a one-line change in the caller, not a change to this class.
  #
  # Since ticket #103 the model is the brain (ModelConfig.resolve) and the
  # request is OpenAI-compatible: the prompt plus its image go over one chat
  # call. When the brain is not answering there is no fallback to route to, so
  # the result is a recorded FAILURE (success: false, model_selection
  # 'brain_unavailable') and the caller ships the placeholder -- exactly the
  # floor the Ollama path fell to when IT was down, now with the reason on the
  # row instead of a timeout.
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
      raise ArgumentError, 'Photo must have a readable image' unless image_readable?

      # Get image as base64
      image_base64 = encode_image

      # Build vision prompt
      prompt = build_vision_prompt

      # Call the brain with vision
      choice = model_choice
      return unavailable_result(choice) unless choice[:available]

      result = choice[:client].chat(
        messages: [
          {
            role: 'user',
            content: prompt
          }
        ],
        temperature: 0.7,
        images: [ image_base64 ]
      )

      # Process the generated caption
      caption_text = result[:text]
      processed = PostProcessor.process(caption_text, @persona.caption_config)

      Result.new(
        text: processed[:text],
        metadata: build_metadata(processed, result, choice),
        success: processed[:compliant]
      )
    rescue StandardError => e
      # model_choice (the memoised method, not a local): the guard raises above
      # fire before the local is assigned, and the metadata must still record
      # the serving-home state the call was made against.
      ModelConfig.log_failure(component: 'vision', error: e, photo_id: @photo&.id)
      failure_result(model_choice, "#{e.class}: #{e.message}")
    end

    private

    # The guard must match what encode_image can ACTUALLY do: it prefers the
    # photo's local/NAS file and only falls back to the ActiveStorage blob, so
    # requiring an ATTACHMENT refused path-only photos this class could encode --
    # which is every render the growth harness imports. Whether the CALLER routes
    # a path-only photo here is a separate, deliberate product decision (pinned
    # in spec/commands/post_automation/generate_caption_spec.rb); this guard only
    # refuses a photo with no readable bytes at all, so it can never reject work
    # it is capable of doing.
    def image_readable?
      ImageEncoder.readable?(@photo)
    end

    # Resolved once per call: the read path and the caption path share the same
    # serving home (ModelConfig.resolve -- the brain), and the metadata must
    # record the same choice the client was built from.
    def model_choice
      @model_choice ||= ModelConfig.resolve
    end

    def encode_image
      ImageEncoder.encode_base64(@photo)
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

    def build_metadata(processed, ai_result, choice)
      {
        model: ai_result[:model] || choice[:model],
        requested_model: choice[:model],
        model_selection: choice[:reason],
        timeout: choice[:timeout],
        generator: 'vision',
        word_count: processed[:text].split.size,
        char_count: processed[:text].length,
        compliant: processed[:compliant],
        warnings: processed[:warnings] || []
      }
    end

    # The brain is not answering. Recorded as a failure with the selection
    # reason, so the placeholder this caller ships is COUNTABLE and explainable
    # after the fact (the exact property the Ollama placeholder era lacked).
    def unavailable_result(choice)
      ModelConfig.log_failure(component: 'vision',
                              error: ModelConfig::UnavailableError.new(choice[:reason]),
                              photo_id: @photo&.id)
      failure_result(choice, "brain serving home not answering (#{choice[:endpoint]})")
    end

    def failure_result(choice, error)
      Result.new(
        text: '',
        metadata: { error: error, vision: true,
                    model: choice[:model],
                    requested_model: choice[:model],
                    model_selection: choice[:reason],
                    timeout: choice[:timeout] },
        success: false
      )
    end
  end
end
