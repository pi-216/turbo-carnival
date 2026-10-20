# frozen_string_literal: true

class Scheduling::PostsController < ApplicationController
  before_action :set_persona
  before_action :set_photo, only: [ :new, :create, :suggest_caption ]

  def index
    # Show available photos for manual post creation AND existing posts
    result = Photos::ListAvailable.call(persona: @persona, pillar_id: params[:pillar_id])
    @photos = result.photos

    # Also show existing scheduled, draft, and posted posts
    @scheduled_posts = Scheduling::Post
      .where(persona_id: @persona.id, status: "scheduled")
      .includes(:photo, :content_suggestion)
      .order(scheduled_at: :asc)

    @draft_posts = Scheduling::Post
      .where(persona_id: @persona.id, status: "draft")
      .includes(:photo, :content_suggestion)
      .order(scheduled_at: :asc)

    @posted_posts = Scheduling::Post
      .where(persona_id: @persona.id, status: "posted")
      .includes(:photo, :content_suggestion)
      .order(updated_at: :desc)
      .limit(10)

    @pillars = @persona.content_pillars.order(:name)
  end

  def browse_photos
    # Redirect to index - we show both photos and posts there
    redirect_to persona_scheduling_posts_path(@persona)
  end

  def destroy
    @post = Scheduling::Post.find(params[:id])

    if @post.persona_id != @persona.id
      redirect_to persona_scheduling_posts_path(@persona), alert: "Unauthorized"
      return
    end

    @post.destroy
    redirect_to persona_scheduling_posts_path(@persona), notice: "Post deleted"
  end

  def suggest_next
    result = PostAutomation::AutoCreateNextPost.call(persona: @persona)

    if result.success?
      redirect_to persona_scheduling_posts_path(@persona),
                  notice: "✅ Post automatically created and scheduled for #{result.post.scheduled_at.strftime('%b %d at %I:%M %p')}! Caption generated with #{result.caption_metadata[:model]}"
    else
      redirect_to persona_scheduling_posts_path(@persona),
                  alert: "Failed to create post: #{result.full_error_message}"
    end
  end

  def new
    @post = Scheduling::Post.new(photo: @photo, persona: @photo.persona)
    @suggested_caption = params[:suggested_caption]

    # Strategy metadata if coming from suggest_next
    @strategy_name = params[:strategy_name]
    @optimal_time = params[:optimal_time]
    @suggested_hashtags = params[:suggested_hashtags]
  end

  def create
    @post = Scheduling::Post.new(post_params)
    @post.photo = @photo
    @post.persona = @photo.persona

    if params[:commit] == "Post Now"
      create_and_post_now
    else
      create_and_schedule
    end
  end

  def suggest_caption
    load_caption_services

    start_time = Time.current

    # Use vision-based generator if image is attached
    result = if @photo.image.attached?
      CaptionGeneration::VisionGenerator.generate(
        photo: @photo,
        persona: @photo.persona,
        content_pillar: @photo.content_pillar
      )
    else
      # Fallback to text-based generator
      CaptionGeneration::Generator.generate(
        photo: @photo,
        persona: @photo.persona,
        cluster: @photo.content_pillar
      )
    end

    generation_time = (Time.current - start_time).round(1)

    if result.success?
      @suggested_caption = result.text
      @suggestion_metadata = result.metadata.merge(
        generation_time: generation_time,
        word_count: result.text.split.size
      )
      redirect_to new_persona_scheduling_post_path(persona_id: @persona.id, photo_id: @photo.id, suggested_caption: @suggested_caption)
    else
      redirect_to new_persona_scheduling_post_path(persona_id: @persona.id, photo_id: @photo.id), alert: "Caption generation failed: #{result.metadata[:error]}"
    end
  end

  private

  def set_persona
    @persona = Persona.find(params[:persona_id])
  end

  def set_photo
    photo_id = params[:photo_id] || params[:id] || params.dig(:scheduling_post, :photo_id)
    @photo = ContentPillars::Photo.find(photo_id)
  end

  def post_params
    params.require(:scheduling_post).permit(:caption, :scheduled_at, :status)
  end

  def create_and_post_now
    result = Scheduling::SchedulePost.call(
      photo: @photo,
      persona: @photo.persona,
      caption: post_params[:caption]
    )

    if result.success?
      redirect_to persona_scheduling_posts_path(@persona), notice: "Post published to Instagram! ID: #{result.post.provider_post_id}"
    else
      @post.errors.add(:base, result.errors.join(", "))
      flash.now[:alert] = "Failed to post: #{result.errors.join(', ')}"
      render :new, status: :unprocessable_entity
    end
  end

  def create_and_schedule
    @post.caption = post_params[:caption]
    @post.status = "scheduled"
    @post.scheduled_at = post_params[:scheduled_at] || 1.hour.from_now

    if @post.save
      redirect_to persona_scheduling_posts_path(@persona), notice: "Post scheduled for #{@post.scheduled_at.strftime('%b %d at %I:%M %p')}"
    else
      flash.now[:alert] = "Failed to save post: #{@post.errors.full_messages.join(', ')}"
      render :new, status: :unprocessable_entity
    end
  end

  def load_caption_services
    Dir["packs/caption_generation/app/services/caption_generation/*.rb"].sort.each { |f| load f }
    # The caption path's serving home is the brain (ticket #103); load its
    # client explicitly because lib/ai is not a Zeitwerk root.
    load "lib/ai/brain_client.rb" unless defined?(AI::BrainClient)
  end
end
