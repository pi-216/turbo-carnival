# frozen_string_literal: true

module CaptionGeneration
  class Generator
    def self.generate(photo:, persona:, cluster: nil, options: {})
      new(photo: photo, persona: persona, cluster: cluster, options: options).generate
    end

    def initialize(photo:, persona:, cluster: nil, options: {})
      @photo = photo
      @persona = persona
      @cluster = cluster
      @options = options
    end

    def generate
      raise ArgumentError, 'Persona caption_config is required' unless @persona.caption_config

      context = ContextBuilder.build(photo: @photo, cluster: @cluster)
      recent_captions = fetch_recent_captions
      repetition_avoid_list = RepetitionChecker.extract_phrases(recent_captions)

      prompt = PromptBuilder.build(
        persona: @persona,
        context: context,
        avoid_phrases: repetition_avoid_list
      )

      caption_text = generate_caption(prompt)
      processed = PostProcessor.process(caption_text, @persona.caption_config)

      Result.new(
        text: processed[:text],
        metadata: build_metadata(processed, context),
        success: processed[:compliant]
      )
    rescue StandardError => e
      ModelConfig.log_failure(component: 'text', error: e, photo_id: @photo&.id)
      Result.new(
        text: '',
        metadata: { error: e.message, model: ModelConfig.model, timeout: ModelConfig.timeout },
        success: false
      )
    end

    private

    def fetch_recent_captions
      Scheduling::Post
        .where(persona_id: @persona.id)
        .where.not(caption: [nil, ''])
        .order(created_at: :desc)
        .limit(20)
        .pluck(:caption)
    end

    def generate_caption(prompt)
      load 'lib/ai/ollama_client.rb' unless defined?(AI::OllamaClient)

      client = AI::OllamaClient.new(model: ModelConfig.model, timeout: ModelConfig.timeout)

      result = client.chat(
        messages: [
          { role: 'system', content: prompt[:system] },
          { role: 'user', content: prompt[:user] }
        ],
        temperature: 0.8
      )

      result[:text]
    end

    def build_metadata(processed, context)
      {
        model: ModelConfig.model,
        timeout: ModelConfig.timeout,
        length: processed[:length],
        compliant: processed[:compliant],
        cluster: context[:cluster_name],
        persona: @persona.name,
        generated_at: Time.current
      }
    end
  end
end
