# frozen_string_literal: true

module CampaignPlanning
  class CreateFromLlm
    class ValidationError < StandardError; end

    def initialize(params)
      @params = params
      @persona = Persona.find_by(id: params[:persona_id])
      @errors = []
    end

    def call
      ActiveRecord::Base.transaction do
        validate!
        create_gap_analysis
        create_content_suggestions_and_posts

        {
          campaign: @gap_analysis,
          suggestions: @suggestions,
          posts: @posts
        }
      end
    rescue ActiveRecord::RecordInvalid => e
      raise ValidationError, e.message
    end

    private

    def validate!
      raise ValidationError, "Persona not found" unless @persona

      posts = @params[:posts] || []
      raise ValidationError, "Posts array required" if posts.empty?

      posts.each_with_index do |post_spec, idx|
        validate_post_spec(post_spec, idx)
      end

      raise ValidationError, @errors.join("; ") if @errors.any?
    end

    def validate_post_spec(post_spec, idx)
      post_num = idx + 1

      if post_spec[:scheduled_at].present?
        begin
          scheduled_time = Time.zone.parse(post_spec[:scheduled_at].to_s)
          if scheduled_time < Time.current
            @errors << "Post ##{post_num}: scheduled_at must be in the future"
          end
        rescue ArgumentError
          @errors << "Post ##{post_num}: invalid scheduled_at format"
        end
      end

      if post_spec[:image_prompt].blank?
        @errors << "Post ##{post_num}: image_prompt cannot be blank"
      end

      if post_spec[:title].blank?
        @errors << "Post ##{post_num}: title cannot be blank"
      end
    end

    def create_gap_analysis
      @gap_analysis = GapAnalysis.create!(
        persona: @persona,
        analyzed_at: Time.current,
        recommendations: {
          campaign_name: @params[:campaign_name],
          strategy_metadata: @params[:strategy_metadata] || {},
          created_by: "llm",
          model: @params[:model] || "unknown",
          created_at: Time.current.iso8601
        }
      )
    end

    def create_content_suggestions_and_posts
      @suggestions = []
      @posts = []

      (@params[:posts] || []).each do |post_spec|
        pillar = find_or_create_pillar(post_spec[:content_pillar_name])

        suggestion = create_content_suggestion(pillar, post_spec)
        post = create_draft_post(suggestion, post_spec)

        @suggestions << suggestion
        @posts << post
      end
    end

    def create_content_suggestion(pillar, post_spec)
      ContentSuggestion.create!(
        gap_analysis: @gap_analysis,
        content_pillar: pillar,
        title: post_spec[:title],
        description: post_spec[:description],
        prompt_data: {
          prompt: post_spec[:image_prompt],
          llm_metadata: {
            scheduled_at: post_spec[:scheduled_at],
            caption_draft: post_spec[:caption_draft],
            hashtags: post_spec[:hashtags] || [],
            format: post_spec[:format],
            created_by_llm: true
          }
        },
        status: "pending"
      )
    end

    def create_draft_post(suggestion, post_spec)
      Scheduling::Post.create!(
        persona: @persona,
        content_suggestion: suggestion,
        status: "draft",
        scheduled_at: post_spec[:scheduled_at],
        caption: post_spec[:caption_draft],
        hashtags: post_spec[:hashtags] || [],
        caption_metadata: {
          format: post_spec[:format],
          generated_by: "llm"
        },
        strategy_name: "llm_campaign"
      )
    end

    def find_or_create_pillar(name)
      return @persona.content_pillars.first if name.blank?

      @persona.content_pillars.find_or_create_by!(name: name) do |pillar|
        pillar.description = "Auto-created by LLM campaign"
        pillar.weight = 1.0  # Low weight to avoid exceeding 100%
        pillar.priority = 3
        pillar.active = true
      end
    end
  end
end
