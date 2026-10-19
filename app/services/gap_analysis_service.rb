# frozen_string_literal: true

class GapAnalysisService
  def initialize(persona)
    @persona = persona
  end

  def analyze!
    coverage_data = calculate_coverage
    recommendations = generate_recommendations(coverage_data)

    gap_analysis = GapAnalysis.create!(
      persona: @persona,
      analyzed_at: Time.current,
      coverage_data: coverage_data,
      recommendations: recommendations
    )

    create_suggestions(gap_analysis, recommendations)

    gap_analysis
  end

  private

  def calculate_coverage
    pillars = @persona.content_pillars.includes(:photos)

    pillars.map do |pillar|
      existing_prompts = pillar.photos.joins(:image_candidate)
                              .joins("INNER JOIN pipeline_runs ON image_candidates.pipeline_run_id = pipeline_runs.id")
                              .pluck("pipeline_runs.prompt")
                              .compact.uniq

      {
        pillar_id: pillar.id,
        pillar_name: pillar.name,
        total_photos: pillar.photos.count,
        last_photo_at: pillar.photos.maximum(:created_at),
        existing_prompts: existing_prompts,
        coverage_score: calculate_pillar_score(pillar)
      }
    end
  end

  def calculate_pillar_score(pillar)
    total_photos = pillar.photos.count
    recency_score = calculate_recency_score(pillar)

    # Simpler scoring: 60% based on photo count, 40% on recency
    (total_photos * 0.6 + recency_score * 0.4).round(2)
  end

  def calculate_recency_score(pillar)
    last_photo_at = pillar.photos.maximum(:created_at)

    return 0 if last_photo_at.nil?

    days_ago = (Time.current - last_photo_at) / 1.day

    if days_ago <= 7
      100
    elsif days_ago <= 30
      50
    elsif days_ago <= 60
      25
    else
      0
    end
  end

  def generate_recommendations(coverage_data)
    sorted_pillars = coverage_data.sort_by { |p| p[:coverage_score] }

    sorted_pillars.first(3).map do |pillar_data|
      generate_pillar_recommendation(pillar_data)
    end.compact
  end

  def generate_pillar_recommendation(pillar_data)
    pillar = @persona.content_pillars.find(pillar_data[:pillar_id])

    {
      pillar_id: pillar.id,
      pillar_name: pillar.name,
      current_photo_count: pillar_data[:total_photos],
      reason: generate_reason(pillar_data),
      existing_prompts: pillar_data[:existing_prompts]
    }
  end

  def generate_reason(pillar_data)
    if pillar_data[:total_photos].zero?
      "No content yet for this pillar"
    elsif pillar_data[:last_photo_at].nil? || pillar_data[:last_photo_at] < 60.days.ago
      "Content is outdated (last photo: #{pillar_data[:last_photo_at]&.to_date || 'never'})"
    else
      "Low coverage - needs more photos"
    end
  end

  def create_suggestions(gap_analysis, recommendations)
    recommendations.each do |rec|
      pillar = ContentPillar.find(rec[:pillar_id])

      ai_content = generate_ai_suggestion(pillar, rec[:existing_prompts])

      ContentSuggestion.create!(
        gap_analysis: gap_analysis,
        content_pillar: pillar,
        title: ai_content[:title],
        description: ai_content[:description],
        prompt_data: {
          prompt: ai_content[:prompt],
          reason: rec[:reason],
          existing_prompts: rec[:existing_prompts]
        },
        status: "pending"
      )
    end
  end

  def generate_ai_suggestion(pillar, existing_prompts)
    caption_config = @persona.caption_config
    persona_style = []

    if caption_config
      persona_style = [ caption_config.tone, caption_config.style, caption_config.voice ].compact
    end

    context = {
      persona_name: @persona.name,
      persona_style: persona_style,
      persona_topics: [],
      pillar_name: pillar.name,
      pillar_description: pillar.description,
      pillar_guidelines: pillar.guidelines,
      existing_prompts: existing_prompts,
      existing_prompts_count: existing_prompts.size
    }

    call_openai_api(context)
  end

  def call_openai_api(context)
    require Rails.root.join("lib", "ai", "gemini_client")

    unless ENV["GEMINI_API_KEY"].present?
      Rails.logger.warn("Gemini API key not configured, using fallback suggestions")
      return generate_fallback_suggestion(context)
    end

    client = AI::GeminiClient.new
    prompt = build_ai_prompt_text(context)

    content = client.generate(
      prompt,
      system: "You are a creative content strategist helping generate unique Instagram photo concepts.",
      temperature: 0.8,
      max_tokens: 4000
    )

    parse_ai_response(content)
  rescue => e
    Rails.logger.error("Gemini API error: #{e.message}")
    generate_fallback_suggestion(context)
  end

  def generate_fallback_suggestion(context)
    {
      title: "Manual suggestion needed",
      description: "AI unavailable. Please create content for the #{context[:pillar_name]} pillar.",
      prompt: "#{context[:pillar_name]} content"
    }
  end

  def build_ai_prompt_text(context)
    <<~PROMPT
      Generate a unique Instagram photo concept for persona "#{context[:persona_name]}".

      Persona style: #{context[:persona_style].join(', ')}
      Persona topics: #{context[:persona_topics].join(', ')}

      Content Pillar: #{context[:pillar_name]}
      Description: #{context[:pillar_description]}
      Guidelines: #{context[:pillar_guidelines]}

      IMPORTANT: We already have #{context[:existing_prompts_count]} photos with these prompts:
      #{context[:existing_prompts].take(10).map { |p| "- #{p}" }.join("\n")}

      Please suggest a DIFFERENT, UNIQUE photo concept that:
      1. Fits the persona's style and topics
      2. Aligns with the pillar "#{context[:pillar_name]}"
      3. Is COMPLETELY DIFFERENT from existing prompts (avoid repetition)
      4. Is specific and actionable for AI image generation
      5. Explores a fresh angle or theme within this pillar

      Provide:
      1. A short title (2-5 words)
      2. A detailed description (2-3 sentences)
      3. A specific AI image generation prompt

      Format as JSON:
      {
        "title": "...",
        "description": "...",
        "prompt": "..."
      }
    PROMPT
  end

  def parse_ai_response(response)
    return { title: "AI Suggestion", description: "No response", prompt: "Manual entry needed" } if response.nil? || response.empty?

    # Remove markdown code blocks if present
    cleaned_response = response.gsub(/```json\s*|\s*```/, "")

    # Extract JSON object
    json_match = cleaned_response.match(/\{.*\}/m)
    return { title: "AI Suggestion", description: response, prompt: response } unless json_match

    parsed = JSON.parse(json_match[0])

    # Return with symbol keys for consistency
    {
      title: parsed["title"] || "AI Suggestion",
      description: parsed["description"] || "",
      prompt: parsed["prompt"] || ""
    }
  rescue JSON::ParserError => e
    Rails.logger.error("Failed to parse AI response: #{e.message}")
    Rails.logger.error("Response was: #{response}")
    { title: "AI Suggestion", description: response, prompt: response }
  end
end
