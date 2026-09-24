# frozen_string_literal: true

module Api
  class CampaignsController < ApplicationController
    skip_before_action :verify_authenticity_token

    def create
      result = CampaignPlanning::CreateFromLlm.new(campaign_params).call

      render json: {
        campaign: campaign_json(result[:campaign]),
        suggestions: result[:suggestions].map { |s| suggestion_json(s) },
        posts: result[:posts].map { |p| post_json(p) }
      }, status: :created
    rescue CampaignPlanning::CreateFromLlm::ValidationError => e
      render json: {
        error: "Validation failed",
        details: e.message.split("; ")
      }, status: :unprocessable_entity
    rescue StandardError => e
      Rails.logger.error("Campaign creation failed: #{e.message}\n#{e.backtrace.join("\n")}")
      render json: {
        error: "Internal server error",
        message: e.message
      }, status: :internal_server_error
    end

    private

    def campaign_params
      params.permit(
        :persona_id,
        :campaign_name,
        :model,
        strategy_metadata: {},
        posts: [
          :title,
          :description,
          :content_pillar_name,
          :image_prompt,
          :scheduled_at,
          :caption_draft,
          :format,
          hashtags: []
        ]
      ).to_h.deep_symbolize_keys
    end

    def campaign_json(gap_analysis)
      {
        id: gap_analysis.id,
        persona_id: gap_analysis.persona_id,
        name: gap_analysis.recommendations["campaign_name"],
        created_at: gap_analysis.created_at.iso8601,
        gap_analysis_id: gap_analysis.id
      }
    end

    def suggestion_json(suggestion)
      {
        id: suggestion.id,
        title: suggestion.title,
        content_pillar_id: suggestion.content_pillar_id,
        status: suggestion.status,
        draft_post_id: Scheduling::Post.find_by(content_suggestion_id: suggestion.id)&.id
      }
    end

    def post_json(post)
      {
        id: post.id,
        scheduled_at: post.scheduled_at&.iso8601,
        status: post.status,
        has_photo: post.photo_id.present?,
        content_suggestion_id: post.content_suggestion_id
      }
    end
  end
end
