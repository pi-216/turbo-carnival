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
        metadata: { error: e.message, model: model_choice[:model],
                    requested_model: ModelConfig.model,
                    model_selection: model_choice[:reason],
                    timeout: model_choice[:timeout] },
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

      choice = model_choice
      client = AI::OllamaClient.new(model: choice[:model], timeout: choice[:timeout],
                                    keep_alive: choice[:keep_alive])

      result = client.chat(
        messages: [
          { role: 'system', content: prompt[:system] },
          { role: 'user', content: prompt[:user] }
        ],
        temperature: 0.8
      )

      result[:text]
    end

    # Resolved once per call: which model answers depends on what Ollama has
    # resident right now (see ModelConfig.resolve), and the metadata must record
    # the same choice the client was built with.
    def model_choice
      @model_choice ||= ModelConfig.resolve
    end

    def build_metadata(processed, context)
      {
        model: model_choice[:model],
        requested_model: ModelConfig.model,
        model_selection: model_choice[:reason],
        timeout: model_choice[:timeout],
        length: processed[:length],
        compliant: processed[:compliant],
        cluster: context[:cluster_name],
        persona: @persona.name,
        generated_at: Time.current
      }
    end
  end
end
