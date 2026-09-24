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
    def self.suggest(pillar:, persona:, existing_clusters: [], existing_photos: [])
      new(pillar: pillar, persona: persona, existing_clusters: existing_clusters, existing_photos: existing_photos).suggest
    end

    def initialize(pillar:, persona:, existing_clusters: [], existing_photos: [])
      @pillar = pillar
      @persona = persona
      @existing_clusters = existing_clusters
      @existing_photos = existing_photos
    end

    def suggest
      context = build_context

      if ai_available?
        generate_suggestions_with_ai(@pillar, context)
      else
        generate_fallback_suggestions
      end
    rescue StandardError => e
      Rails.logger.error("AI suggestion failed: #{e.message}")
      generate_fallback_suggestions
    end

    private

    def ai_available?
      ENV['GEMINI_API_KEY'].present?
    end

    def generate_suggestions_with_ai(pillar, context)
      require Rails.root.join('lib', 'ai', 'gemini_client') unless defined?(AI::GeminiClient)

      client = AI::GeminiClient.new

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
        persona_topics: @persona.caption_config&.dig('topics') || [],
        existing_cluster_keywords: @existing_clusters.flat_map { |c| c.keywords || [] }.uniq,
        existing_photo_count: @existing_photos.size,
        recent_photo_descriptions: @existing_photos.last(10).map { |p| p.caption || 'untitled' }
      }
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
