# frozen_string_literal: true

module Growth
  # The nightly planner window (PRD 0001, ticket #64).
  #
  # Founder ruling, 2026-10-19: the planner runs ONCE A NIGHT. The local brain is
  # ~22.3 GiB of a 24 GiB card and cannot be resident at tick time, so it owns the
  # 4090 for one bounded window owned by bin/brain_plan_nightly.sh — which holds the
  # GPU claim and starts/stops the seat. This class only PLANS and PERSISTS, so it is
  # exercisable with no GPU and no claim (the wrapper is the only GPU-touching half).
  #
  # Fail-soft by design: a down seat writes nothing and is not an error. The hourly
  # cadence loop reaches the brain only through the pull-based in-app path (#27) and
  # never waits on this window.
  class NightlyPlanner
    Result = Struct.new(:seat_up, :personas, :pillars, :suggestions, keyword_init: true) do
      def written?
        suggestions.positive?
      end
    end

    def initialize(persona_name: nil)
      @persona_name = persona_name
    end

    def call
      brain = brain_client
      return Result.new(seat_up: false, personas: 0, pillars: 0, suggestions: 0) unless brain.available?

      personas = target_personas
      written = 0
      pillar_count = 0

      personas.each do |persona|
        # Only CURRENT pillars (active, inside their date window) are planned for.
        pillars = persona.content_pillars.current.by_priority
        next if pillars.empty?

        gap = GapAnalysis.create!(
          persona: persona, analyzed_at: Time.current, recommendations: provenance(brain)
        )
        pillar_count += pillars.size
        pillars.each { |pillar| written += persist(gap, pillar) }
        record(persona, written, pillars.size, gap)
      end

      Result.new(seat_up: true, personas: personas.size, pillars: pillar_count, suggestions: written)
    end

    private

    def brain_client
      require Rails.root.join("lib", "ai", "brain_client") unless defined?(AI::BrainClient)
      AI::BrainClient.new
    end

    def target_personas
      if @persona_name.present?
        [ Persona.find_by(name: @persona_name) ].compact
      else
        Persona.all.to_a
      end
    end

    # The seat's location is recorded on the gap analysis so a proposal can be traced
    # to the window that produced it (same provenance shape the LLM campaign path uses).
    def provenance(brain)
      cfg = AI::BrainClient.config
      {
        created_by: "brain_nightly",
        model: cfg[:model],
        endpoint: cfg[:endpoint],
        created_at: Time.current.iso8601
      }.merge(brain.respond_to?(:provenance) ? brain.provenance : {})
    end

    def persist(gap, pillar)
      count = 0
      GapAnalysisAi::Suggester.suggest(pillar: pillar, persona: gap.persona).each do |suggestion|
        ContentSuggestion.create!(
          gap_analysis: gap,
          content_pillar: pillar,
          title: suggestion[:name].presence || "#{pillar.name} idea",
          description: (suggestion[:description].presence || suggestion[:name]).to_s,
          prompt_data: {
            source: suggestion[:source],
            example: suggestion[:example],
            keywords: suggestion[:keywords] || []
          },
          status: "pending"
        )
        count += 1
      end
      count
    end

    def record(persona, written, pillars, gap)
      goal = Growth::Goal.active.for_persona(persona).first
      return unless goal

      Growth::Decision.create!(
        goal: goal,
        action: "brain_planned",
        reason: "nightly plan on the local brain — #{written} suggestions across #{pillars} pillars " \
                "(gap #{gap.id}, seat #{AI::BrainClient.config[:endpoint]})",
        decided_at: Time.current
      )
    rescue StandardError => e
      Rails.logger.error("NightlyPlanner could not record the decision: #{e.message}")
    end
  end
end
