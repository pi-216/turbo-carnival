class ContentPillarsController < ApplicationController
  before_action :set_persona
  before_action :set_pillar, only: [:show, :edit, :update, :destroy, :suggest]

  def show
    @content_pillar = @pillar # Alias for view compatibility
    @photos = @pillar.photos.includes(:image_candidate).order(created_at: :desc)
  end

  def new
    @pillar = @persona.content_pillars.build
    calculate_remaining_weight
  end

  def create
    @pillar = @persona.content_pillars.build(pillar_params)
    
    if @pillar.save
      redirect_to persona_path(@persona), notice: "Content pillar '#{@pillar.name}' was successfully created."
    else
      calculate_remaining_weight
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    calculate_remaining_weight
  end

  def update
    if @pillar.update(pillar_params)
      redirect_to persona_pillar_path(@persona, @pillar), notice: "Content pillar was successfully updated."
    else
      calculate_remaining_weight
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    if @pillar.photos.any?
      redirect_to persona_path(@persona), alert: "Cannot delete pillar with existing photos. Please delete or reassign photos first."
    else
      @pillar.destroy
      redirect_to persona_path(@persona), notice: "Content pillar was successfully deleted."
    end
  end

  def suggest
    existing_photos = @pillar.photos
    
    @suggestions = GapAnalysisAi::Suggester.suggest(
      pillar: @pillar,
      persona: @persona,
      existing_photos: existing_photos
    )
    
    render :suggest
  rescue StandardError => e
    redirect_to persona_pillar_path(@persona, @pillar), alert: "Error generating suggestions: #{e.message}"
  end

  private

  def set_persona
    @persona = Persona.find(params[:persona_id])
  end

  def set_pillar
    @pillar = @persona.content_pillars.find(params[:id])
  end

  def pillar_params
    params.require(:content_pillar).permit(
      :name, :description, :weight, :priority, 
      :active, :start_date, :end_date, :target_posts_per_week
    )
  end

  def calculate_remaining_weight
    current_weight = @pillar.persisted? ? @pillar.weight : 0
    @used_weight = @persona.content_pillars.active.where.not(id: @pillar.id).sum(:weight)
    @remaining_weight = 100 - @used_weight
    @available_weight = @remaining_weight + current_weight
  end
end
