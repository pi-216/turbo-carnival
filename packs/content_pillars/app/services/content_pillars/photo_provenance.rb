# frozen_string_literal: true

require 'digest'

module ContentPillars
  # The synthetic mark recorded when a render becomes a Photo
  # (openspec/changes/add-synthetic-provenance, task 1.3).
  #
  # This is the DATABASE half of the mark: it puts nothing into the image bytes,
  # which is exactly why `embedded` is recorded as false. A row marked here must
  # never be read as "the published asset carries a machine-readable mark" --
  # embedding into the served bytes is a later phase of the same change (tasks
  # 2.x), and until it lands the publish gate (3.x) has nothing to gate on.
  #
  # Attribution values are recorded only when the run actually carries them.
  # Pillar 2 mandates `base_model` / `seed` / `prompt_hash` on every render, but
  # measured 2026-09-21 the growth path persists only `sync_producer` in
  # `pipeline_runs.variables` (10 of 457 runs carry a seed), so a provenance hash
  # that invented those fields would be worse than one that omits them.
  module PhotoProvenance
    DIGITAL_SOURCE_TYPE = 'trainedAlgorithmicMedia'

    module_function

    # Provenance for a photo imported from a completed render. `run` is
    # duck-typed (id / prompt / variables / quality_metrics) so this pack keeps
    # its dependency list unchanged.
    def for_run(run)
      variables = run_variables(run)

      {
        'digital_source_type' => DIGITAL_SOURCE_TYPE,
        'source' => 'render',
        'embedded' => false,
        'recorded_at' => Time.current.utc.iso8601,
        'run_id' => run&.id,
        'prompt_hash' => prompt_hash(run),
        'seed' => presence(variables['seed'] || variables[:seed]),
        'base_model' => presence(variables['base_model'] || variables[:base_model]),
        'quality_metrics' => run_quality_metrics(run)
      }.compact
    end

    # Provenance for a photo that predates this capability (task 1.2). Every
    # photo in this corpus came out of a render, so it is marked synthetic -- with
    # `embedded: false` and a `backfill` source, because nothing was recorded at
    # its creation and no asset-level mark was ever applied.
    def backfilled
      {
        'digital_source_type' => DIGITAL_SOURCE_TYPE,
        'source' => 'backfill',
        'embedded' => false,
        'recorded_at' => Time.current.utc.iso8601,
        'note' => 'pre-dates provenance tracking; nothing was recorded at creation'
      }
    end

    def run_variables(run)
      return {} unless run.respond_to?(:variables)

      run.variables || {}
    end

    def prompt_hash(run)
      prompt = run.respond_to?(:prompt) ? run.prompt : nil
      return nil if prompt.to_s.strip.empty?

      Digest::SHA256.hexdigest(prompt.to_s)
    end

    def run_quality_metrics(run)
      metrics = run.respond_to?(:quality_metrics) ? run.quality_metrics : nil
      return nil unless metrics.is_a?(Hash) && metrics.any?

      metrics
    end

    def presence(value)
      value.presence
    end
  end
end
