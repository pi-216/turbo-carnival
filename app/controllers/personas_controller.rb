# frozen_string_literal: true

class PersonasController < ApplicationController
  before_action :set_persona, only: [ :show, :edit, :update, :destroy ]

  def index
    @personas = Persona.all.order(:name)
  end

  def show
    @pillars = @persona.content_pillars.order(:name)
    @total_photos = @persona.photos.count

    # Use command to get available photos count
    result = Photos::ListAvailable.call(persona: @persona)
    @unposted_photos = result.photos.count

    # Get upcoming scheduled posts
    @upcoming_posts = Scheduling::Post
      .where(persona: @persona, status: [ "draft", "scheduled" ])
      .where("scheduled_at > ?", Time.current)
      .order(:scheduled_at)
      .limit(10)
      .includes(photo: :content_pillar)

    @scheduled_posts = Scheduling::Post.where(persona: @persona, status: [ "draft", "scheduled" ]).count
    @posted_count = Scheduling::Post.where(persona: @persona, status: "posted").count
  end

  def new
    @persona = Persona.new
  end

  def create
    result = Personas.create(name: persona_params[:name])

    if result.success?
      redirect_to persona_path(result.persona), notice: "Persona was successfully created."
    else
      @persona = Persona.new(persona_params)
      @persona.errors.add(:base, result.full_error_message)
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @persona.update(persona_params)
      redirect_to persona_path(@persona), notice: "Persona was successfully updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @persona.destroy!
    redirect_to personas_path, notice: "Persona was successfully deleted."
  end

  private

  def set_persona
    @persona = Persona.find(params[:id])
  end

  def persona_params
    params.require(:persona).permit(:name)
  end
end
