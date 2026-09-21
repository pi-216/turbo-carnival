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

    # The mark a photo carries AFTER its asset bytes were verified to carry it
    # (tasks 2.1/2.2). `embedded` is the one field that is allowed to say the
    # published asset is machine-readable, so it is only ever flipped from a
    # read-back of the file we are about to serve -- never from the intention to
    # write it.
    def embedded(provenance, method: 'xmp-png')
      provenance.to_h.merge(
        'embedded' => true,
        'embedded_at' => Time.current.utc.iso8601,
        'embedded_method' => method
      )
    end

    # Write the machine-readable mark into the asset the publish path will serve
    # and return the provenance hash that describes what actually happened.
    # Non-fatal by design: a render that cannot be marked must still become a
    # photo (the publish gate -- not the render -- is where a missing mark is
    # allowed to stop the line).
    def mark_asset(provenance, path)
      result = PhotoAssetMarker.mark!(path, provenance)

      case result
      when :marked, :already_marked
        embedded(provenance, method: result == :already_marked ? 'xmp-existing' : embed_method_for(path))
      else
        provenance.to_h.merge('embed_attempt' => result.to_s)
      end
    end

    # Which carrier the mark used -- recorded so a future reader can tell a PNG
    # iTXt chunk from a JPEG APP1 segment without re-reading the asset.
    def embed_method_for(path)
      File.binread(path, 8).start_with?(PhotoAssetMarker::PNG_SIGNATURE) ? 'xmp-png' : 'xmp-jpeg'
    rescue StandardError
      'xmp'
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
