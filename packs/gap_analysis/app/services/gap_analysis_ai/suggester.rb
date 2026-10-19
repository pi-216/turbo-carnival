# frozen_string_literal: true

# NOTE: this class deliberately does NOT live under a `GapAnalysis` namespace.
# `GapAnalysis` is an ActiveRecord model (`app/models/gap_analysis.rb`) -- a
# CLASS -- so `module GapAnalysis` here raised
# `TypeError: GapAnalysis is not a module` the moment both were loaded, which
# killed eager loading (`RAILS_ENV=production bin/rails zeitwerk:check` aborted,
# i.e. the app could not boot in production at all) and made the pillar
# `#suggest` action return "Error generating suggestions: GapAnalysis is not a
# module" instead of suggestions. Keep the namespace distinct from the model.
module GapAnalysisAi
  class Suggester
    def self.suggest(pillar:, persona:, existing_clusters: [], existing_photos: [], existing_suggestions: [])
      new(pillar: pillar, persona: persona, existing_clusters: existing_clusters,
          existing_photos: existing_photos, existing_suggestions: existing_suggestions).suggest
    end

    def initialize(pillar:, persona:, existing_clusters: [], existing_photos: [], existing_suggestions: [])
      @pillar = pillar
      @persona = persona
      @existing_clusters = existing_clusters
      @existing_photos = existing_photos
      # Prior ContentSuggestions for this pillar. Fed into the prompt so the brain
      # does not re-propose what is already on the board (PRD 0001 nightly planner).
      @existing_suggestions = existing_suggestions
    end

    def suggest
      context = build_context
      client = planner_client
      unless client
        Rails.logger.warn("no planner client (brain down, no hosted key) — template suggestions")
        return generate_fallback_suggestions
      end

      generate_suggestions_with_ai(@pillar, context, client)
    rescue StandardError => e
      Rails.logger.error("AI suggestion failed: #{e.message}")
      generate_fallback_suggestions
    end

    private

    # Prefer the LOCAL UNCENSORED BRAIN (PRD 0001, ticket #27). The hosted model is
    # only a fallback while it is being retired; when neither answers, the template
    # suggestions keep the caller working rather than failing the action.
    def planner_client
      require Rails.root.join('lib', 'ai', 'brain_client') unless defined?(AI::BrainClient)
      brain = AI::BrainClient.new
      return brain if brain.available?

      require Rails.root.join('lib', 'ai', 'gemini_client') unless defined?(AI::GeminiClient)
      ENV['GEMINI_API_KEY'].present? ? AI::GeminiClient.new : nil
    rescue StandardError => e
      Rails.logger.warn("planner client unavailable: #{e.message}")
      ENV['GEMINI_API_KEY'].present? ? AI::GeminiClient.new : nil
    end

    def generate_suggestions_with_ai(pillar, context, client)
      prompt = build_prompt(pillar, context)

      content = client.generate(
        prompt[:user],
        system: prompt[:system],
        temperature: 0.8,
        max_tokens: 1500
      )

      parse_suggestions(content)
    end

    def build_context
      {
        persona_name: @persona.name,
        persona_topics: persona_topics,
        existing_cluster_keywords: existing_keywords,
        existing_titles: @existing_suggestions.map(&:title),
        existing_photo_count: @existing_photos.size,
        recent_photo_descriptions: @existing_photos.last(10).map { |p| p.caption || 'untitled' }
      }
    end

    # Keywords the brain should treat as already-consumed, from both the cluster
    # objects and any prior proposals' stored keywords (jsonb → string keys).
    def existing_keywords
      from_clusters = @existing_clusters.flat_map { |c| c.keywords || [] }
      from_suggestions = @existing_suggestions.flat_map { |s| s.prompt_data&.dig("keywords") || [] }
      (from_clusters + from_suggestions).uniq
    end

    # `caption_config` is a Personas::CaptionConfig (tone/style/voice), NOT a Hash —
    # calling `.dig('topics')` on it raised NoMethodError, which `suggest` rescued
    # into the template fallback, so this planner NEVER reached any model. Read
    # topics defensively across the Hash and object shapes; absence is not an error.
    def persona_topics
      config = @persona.caption_config
      topics = if config.is_a?(Hash)
                 config['topics'] || config[:topics]
      elsif config.respond_to?(:topics)
                 config.topics
      end
      Array(topics)
    end

    def build_prompt(pillar, context)
      system_prompt = <<~PROMPT
        You are a content strategist helping create diverse, engaging Instagram content.

        Persona: #{context[:persona_name]}
        Core Topics: #{context[:persona_topics].join(', ')}

        Your goal is to suggest NEW content ideas that:
        1. Align with the content pillar theme
        2. Are DIFFERENT from existing content (avoid repetition)
        3. Are authentic and natural for this persona
        4. Provide variety and freshness
      PROMPT

      user_prompt = <<~PROMPT
        Content Pillar: #{pillar.name}
        Description: #{pillar.description}

        Existing clusters in this pillar:
        #{context[:existing_cluster_keywords].any? ? context[:existing_cluster_keywords].join(', ') : 'None yet'}

        Titles already proposed for this pillar (do NOT repeat these, or lightly reword them):
        #{context[:existing_titles].any? ? context[:existing_titles].join(', ') : 'None yet'}

        Recent content themes:
        #{context[:recent_photo_descriptions].join("\n")}

        Suggest 5 NEW, FRESH content cluster ideas for this pillar. Each should be:
        - Specific and actionable
        - Different from existing clusters
        - Authentic to the persona
        - Visually interesting

        Format your response as a JSON array with this structure:
        [
          {
            "name": "Cluster name (2-4 words)",
            "description": "What this cluster is about (1 sentence)",
            "keywords": ["keyword1", "keyword2", "keyword3"],
            "example_content": "Specific example of a post in this cluster"
          }
        ]
      PROMPT

      { system: system_prompt, user: user_prompt }
    end

    def parse_suggestions(content)
      # Extract JSON from the response
      json_match = content.match(/\[.*\]/m)
      return generate_fallback_suggestions unless json_match

      suggestions = JSON.parse(json_match[0])
      suggestions.map do |s|
        {
          name: s['name'],
          description: s['description'],
          keywords: s['keywords'] || [],
          example: s['example_content'],
          source: 'ai'
        }
      end
    rescue JSON::ParserError => e
      Rails.logger.error("Failed to parse AI response: #{e.message}")
      generate_fallback_suggestions
    end

    def generate_fallback_suggestions
      [
        {
          name: "#{@pillar.name} Moments",
          description: "Everyday moments related to #{@pillar.name}",
          keywords: [ @pillar.name.downcase, 'lifestyle', 'authentic' ],
          example: "Candid moment capturing #{@pillar.name}",
          source: 'template'
        },
        {
          name: "#{@pillar.name} Details",
          description: "Close-up details and textures",
          keywords: [ @pillar.name.downcase, 'detail', 'aesthetic' ],
          example: "Detail shot highlighting #{@pillar.name}",
          source: 'template'
        }
      ]
    end
  end
end
