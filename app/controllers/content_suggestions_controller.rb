class ContentSuggestionsController < ApplicationController
  before_action :set_persona, only: [ :index ]
  before_action :set_content_suggestion, except: [ :index ]
  before_action :authorize_destroy, only: [ :destroy ]

  def index
    @content_suggestions = ContentSuggestion
      .joins(:gap_analysis)
      .where(gap_analyses: { persona_id: @persona.id })
      .includes(:content_pillar, :gap_analysis)
      .order(created_at: :desc)

    @pending_suggestions = @content_suggestions.pending
    @used_suggestions = @content_suggestions.used
    @rejected_suggestions = @content_suggestions.rejected
  end

  def edit
    # Editing the prompt
  end

  def update
    if @content_suggestion.update(content_suggestion_params)
      redirect_to persona_content_suggestions_path(@content_suggestion.gap_analysis.persona),
                  notice: "Prompt updated successfully"
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def use
    @content_suggestion.mark_as_used!
    redirect_back fallback_location: root_path, notice: "Suggestion marked as used"
  end

  def reject
    @content_suggestion.mark_as_rejected!
    redirect_back fallback_location: root_path, notice: "Suggestion rejected"
  end

  def destroy
    persona = @content_suggestion.gap_analysis.persona
    @content_suggestion.destroy
    redirect_to persona_content_suggestions_path(persona), notice: "Suggestion deleted"
  end

  def generate_image
    # Use the existing sarah1a3 pipeline
    pipeline = Pipeline.first || Pipeline.find_by(name: "sarah1a3")

    unless pipeline
      redirect_back fallback_location: root_path,
                    alert: "No pipeline configured. Please set up a pipeline first."
      return
    end

    # Create pipeline run directly for the pillar
    run = PipelineRun.create!(
      pipeline: pipeline,
      persona: @content_suggestion.gap_analysis.persona,
      content_pillar_id: @content_suggestion.content_pillar_id,
      prompt: @content_suggestion.prompt_data["prompt"],
      name: "Gap Analysis: #{@content_suggestion.title}",
      target_folder: "gap_analysis/#{@content_suggestion.id}",
      status: "pending"
    )

    # Link to draft post if exists (for LLM campaigns)
    post = Scheduling::Post.find_by(content_suggestion: @content_suggestion)
    if post
      post.update!(pipeline_run: run)
      post.start_image_generation! if post.may_start_image_generation?
    end

    @content_suggestion.mark_as_used!

    redirect_to run_path(run),
                notice: "Image generation started! Pipeline will generate candidates for '#{@content_suggestion.title}'"
  end

  private

  def set_persona
    @persona = Persona.find(params[:persona_id])
  end

  def set_content_suggestion
    @content_suggestion = ContentSuggestion.find(params[:id])
  end

  def content_suggestion_params
    params.require(:content_suggestion).permit(:title, :description, :prompt)
  end

  def authorize_destroy
    unless @content_suggestion.status == "rejected"
      redirect_back fallback_location: root_path,
                    alert: "Only rejected suggestions can be deleted"
    end
  end
end
