# frozen_string_literal: true

# Helper for building hierarchical navigation breadcrumbs
# Supports: Dashboard -> Persona -> Pillar -> Run
module NavigationHelper
  # Returns the current navigation context based on controller/action
  # @return [Hash] with :level, :resource, :parent keys
  def current_navigation_context
    case controller_name
    when "personas"
      persona_context
    when "content_pillars"
      pillar_context
    when "runs", "pipeline_runs"
      run_context
    else
      dashboard_context
    end
  end

  # Builds breadcrumb navigation items for sidebar
  # @return [Array<Hash>] array of {label, path, current} hashes
  def navigation_breadcrumbs
    context = current_navigation_context

    case context[:level]
    when :dashboard
      []
    when :persona
      [
        { label: "← Dashboard", path: root_path, icon: :arrow_left }
      ]
    when :pillar
      [
        { label: "← #{context[:parent].name}", path: persona_path(context[:parent]), icon: :arrow_left }
      ]
    when :run
      pillar = context[:parent]
      if pillar
        persona = pillar.persona
        [
          { label: "← #{pillar.name}", path: persona_pillar_path(persona, pillar), icon: :arrow_left }
        ]
      else
        []
      end
    else
      []
    end
  end

  # Returns navigation items for current context
  # @return [Array<Hash>] array of {label, path, current} hashes
  def navigation_items
    context = current_navigation_context

    case context[:level]
    when :dashboard
      dashboard_items
    when :persona
      persona_items(context[:resource])
    when :pillar
      pillar_items(context[:resource])
    when :run
      run_items(context[:resource])
    else
      []
    end
  end

  # Returns the section heading for current context
  def navigation_section_heading
    context = current_navigation_context

    case context[:level]
    when :dashboard
      "Personas"
    when :persona
      "Content Pillars"
    when :pillar
      "Photos"
    when :run
      "Run Details"
    when :run
      "Run Details"
    else
      "Navigation"
    end
  end

  private

  def dashboard_context
    { level: :dashboard, resource: nil, parent: nil }
  end

  def persona_context
    persona = @persona || Persona.find_by(id: params[:id])
    if persona
      { level: :persona, resource: persona, parent: nil }
    else
      dashboard_context
    end
  end

  def pillar_context
    pillar = @pillar || @content_pillar || ContentPillar.find_by(id: params[:id])
    if pillar
      { level: :pillar, resource: pillar, parent: pillar.persona }
    else
      dashboard_context
    end
  end

  def run_context
    run = @run || PipelineRun.find_by(id: params[:id])
    if run && run.content_pillar
      { level: :run, resource: run, parent: run.content_pillar }
    else
      dashboard_context
    end
  end

  def dashboard_items
    Persona.all.map do |persona|
      {
        label: persona.name,
        path: persona_path(persona),
        current: false
      }
    end
  end

  def persona_items(persona)
    return [] unless persona&.content_pillars

    persona.content_pillars.map do |pillar|
      {
        label: pillar.name,
        path: persona_pillar_path(persona, pillar),
        current: pillar.id == params[:id]&.to_i
      }
    end
  end

  def pillar_items(pillar)
    return [] unless pillar

    # Show photos in this pillar
    pillar.photos.order(created_at: :desc).limit(20).map do |photo|
      {
        label: "Photo ##{photo.id}",
        path: "#", # Could link to photo detail if we had one
        current: false
      }
    end
  end

  def run_items(_run)
    # Could show run details, steps, etc.
    []
  end
end
