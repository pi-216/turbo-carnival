class PillarPhotosController < ApplicationController
  before_action :set_persona
  before_action :set_pillar

  def new
    @photo = ContentPillars::Photo.new
  end

  def create
    uploaded_file = params.dig(:content_pillars_photo, :image)

    if uploaded_file.blank?
      Rails.logger.warn("Photo upload failed: no file provided. Params: #{params.inspect}")
      flash.now[:alert] = "Please select an image to upload."
      @photo = ContentPillars::Photo.new
      render :new, status: :unprocessable_entity
      return
    end

    @photo = ContentPillars::Photo.new(
      persona: @persona,
      content_pillar: @pillar,
      path: uploaded_file.original_filename.presence || "manual-upload-#{SecureRandom.uuid}"
    )

    ActiveRecord::Base.transaction do
      @photo.save!
      @photo.image.attach(uploaded_file)
    end

    redirect_to persona_pillar_path(@persona, @pillar), notice: "Photo was successfully uploaded."
  rescue ActiveRecord::RecordInvalid, ActiveStorage::IntegrityError => e
    Rails.logger.warn("Pillar photo upload failed: #{e.class} - #{e.message}")
    flash.now[:alert] = "Could not upload photo. Please try a different image."
    @photo ||= ContentPillars::Photo.new
    render :new, status: :unprocessable_entity
  end

  private

  def set_persona
    @persona = Persona.find(params[:persona_id])
  end

  def set_pillar
    @pillar = @persona.content_pillars.find(params[:pillar_id])
  end
end
