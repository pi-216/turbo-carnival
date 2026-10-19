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
    Result = Struct.new(:seat_up, :personas, :pillars, :suggestions, :skipped_personas, keyword_init: true) do
      def written?
        suggestions.positive?
      end
    end

    def initialize(persona_name: nil, force: false)
      @persona_name = persona_name
      @force = force
    end

    def call
      brain = brain_client
      unless brain.available?
        return Result.new(seat_up: false, personas: 0, pillars: 0, suggestions: 0, skipped_personas: 0)
      end

      written = 0
      pillar_count = 0
      planned = 0
      skipped = 0

      target_personas.each do |persona|
        # IDEMPOTENCE — one plan per persona per night. Without this, every
        # invocation mints a whole new plan and the ledger fills with duplicates
        # (the 2026-10-19 incident: two manual runs wrote 4 gap analyses / 80
        # suggestions). A re-run is a no-op unless force:.
        if !@force && already_planned_today?(persona)
          skipped += 1
          Rails.logger.info("NightlyPlanner: #{persona.name} already planned today — skipping (force: true re-plans)")
          next
        end

        # Only CURRENT pillars (active, inside their date window) are planned for.
        pillars = persona.content_pillars.current.by_priority
        next if pillars.empty?

        gap = GapAnalysis.create!(
          persona: persona, analyzed_at: Time.current, recommendations: provenance(brain)
        )
        pillar_count += pillars.size
        pillars.each { |pillar| written += persist(gap, pillar) }
        record(persona, written, pillars.size, gap)
        planned += 1
      end

      Result.new(seat_up: true, personas: planned, pillars: pillar_count,
                 suggestions: written, skipped_personas: skipped)
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

    # LAYER 2 — write-time dedupe. The brain re-proposes similar clusters night
    # after night; a proposal whose normalized title already exists for this pillar
    # (any status) is dropped, and titles already written in THIS batch are dropped
    # too. LAYER 3 — the prior proposals are also fed back into the prompt
    # (existing_suggestions) so the brain avoids repeats at the source rather than
    # only being filtered after the fact.
    def persist(gap, pillar)
      existing = ContentSuggestion.where(content_pillar: pillar)
      seen = existing.pluck(:title).map { |title| normalize_title(title) }
      count = 0

      GapAnalysisAi::Suggester.suggest(
        pillar: pillar,
        persona: gap.persona,
        existing_suggestions: existing.order(created_at: :desc).limit(20)
      ).each do |suggestion|
        title = (suggestion[:name].presence || "#{pillar.name} idea").to_s
        key = normalize_title(title)
        if seen.include?(key)
          Rails.logger.info("NightlyPlanner: dropped duplicate '#{title}' for #{pillar.name}")
          next
        end
        seen << key

        ContentSuggestion.create!(
          gap_analysis: gap,
          content_pillar: pillar,
          title: title,
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

    # LAYER 1 — has a brain_nightly plan already been written for this persona today?
    def already_planned_today?(persona)
      GapAnalysis.where(persona: persona)
                 .where("recommendations ->> 'created_by' = ?", "brain_nightly")
                 .where(analyzed_at: Time.current.all_day)
                 .exists?
    end

    def normalize_title(title)
      title.to_s.strip.downcase.gsub(/\s+/, " ")
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
