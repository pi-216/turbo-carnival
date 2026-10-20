# frozen_string_literal: true

module Attribution
  # The ONE writer for the attribution spine: a render, its named prompt parts and its LoRA
  # set, written together. Everything that creates a render comes through here.
  #
  # WHY ONE WRITER. A render's input set is worthless if half of it can be written by one
  # path and half by another. The parts arrive AS ARGUMENTS, from whatever CREATED the run --
  # never extracted from the graph or from an assembled prompt afterwards, because a part
  # read back out of a finished string is a guess dressed as a record.
  #
  # WHAT IT REFUSES, each refusal mechanical rather than a note in a document:
  #   * an assembled prompt. `prompt_parts` must be NAMED parts; a String is rejected. A
  #     string cannot be varied, and no consumer may need one to attribute an outcome.
  #   * an empty part set. A render created now must name its axes; an unnamed render is
  #     indistinguishable from the pre-spine corpus and would poison a one-axis query.
  #   * rewriting recorded parts (or LoRAs). Recorded attribution is not editable -- a changed
  #     part is a NEW render. Editing a record in place destroys the comparison it exists to
  #     support, retroactively.
  #
  # Absent stays absent: only the values actually passed are written, so an update fills facts
  # in and never blanks one that was already known.
  class RecordRender < ApplicationCommand
    requires :prompt_parts
    allows :render, :pipeline_run, :image_candidate, :asset,
           :asset_sha256, :asset_path, :asset_byte_size, :asset_width, :asset_height,
           :checkpoint, :seed, :sampler, :scheduler, :steps, :cfg, :denoise,
           :width, :height, :negative_prompt, :workflow_sha256, :workflow_path, :produced_at, :loras

    returns :render

    # The scalar axes of a render, in the order they read in `Attribution::Render#inputs`.
    # `width`/`height` are the RENDER's resolution; `asset_width`/`asset_height` above are the
    # produced file's own dimensions, which are a separate measurement.
    AXES = %i[checkpoint seed sampler scheduler steps cfg denoise width height
              negative_prompt workflow_sha256 workflow_path produced_at].freeze

    def call
      parts = validated_parts
      loras = Array(context.loras)

      ActiveRecord::Base.transaction do
        render = locate_render
        assign_axes(render)
        assign_associations(render)
        render.save!
        write_parts(render, parts)
        write_loras(render, loras)
        context.render = render
      end
    end

    # The write is a single transaction, so a failure leaves no half-written render and
    # there is nothing to undo. It must NOT destroy `context.render`: that row may be an
    # EXISTING one this command was filling in, and deleting it would be destructive cleanup
    # of a record this command did not create.
    def rollback; end

    private

    def validated_parts
      raw = context.prompt_parts

      if raw.is_a?(String)
        stop_and_fail!("prompt_parts must be NAMED parts, not an assembled string: a string " \
                       "cannot be varied, and parsing one back into parts is a guess")
      end

      parts =
        begin
          Attribution::PromptParts.from(raw)
        rescue ArgumentError => e
          stop_and_fail!("prompt_parts rejected: #{e.message}")
        end

      stop_and_fail!("prompt_parts is empty: a render created now must name its prompt parts") if parts.empty?

      parts
    end

    # Idempotence with a real key: a candidate is the image that was actually produced, and
    # `renders.image_candidate_id` is unique -- so re-recording the same candidate updates its
    # render instead of forking a second one. A pipeline run is deliberately NOT a key: one run
    # legitimately produces several renders.
    def locate_render
      return context.render if context.render
      return Attribution::Render.new unless context.image_candidate

      Attribution::Render.find_by(image_candidate_id: context.image_candidate.id) || Attribution::Render.new
    end

    def assign_axes(render)
      AXES.each do |axis|
        value = context.public_send(axis)
        render.public_send("#{axis}=", value) unless value.nil?
      end
    end

    def assign_associations(render)
      render.pipeline_run = context.pipeline_run if context.pipeline_run
      render.image_candidate = context.image_candidate if context.image_candidate

      asset = resolve_asset
      render.asset = asset if asset
    end

    def resolve_asset
      return context.asset if context.asset
      return nil if context.asset_sha256.blank?

      Attribution::Asset.record(
        sha256: context.asset_sha256,
        path: context.asset_path,
        byte_size: context.asset_byte_size,
        width: context.asset_width,
        height: context.asset_height
      )
    end

    def write_parts(render, parts)
      recorded = render.prompt_parts.pluck(:name, :text).to_h

      if recorded.any?
        return if recorded == parts.to_h

        stop_and_fail!("refusing to rewrite recorded prompt parts on render #{render.id}: " \
                       "#{recorded.keys.sort} -> #{parts.names.sort}")
      end

      parts.each_part do |name, text, position|
        render.prompt_parts.create!(name: name, text: text, position: position)
      end
    end

    def write_loras(render, loras)
      return if loras.empty?

      incoming = loras.each_with_index.map { |lora, position| lora_row(lora, position) }
      recorded = render.loras.map do |lora|
        { layer: lora.layer, name: lora.name, strength: lora.strength&.to_f,
          enabled: lora.enabled, position: lora.position }
      end

      if recorded.any?
        return if canonical_loras(recorded) == canonical_loras(incoming)

        stop_and_fail!("refusing to rewrite the recorded LoRA set on render #{render.id}")
      end

      incoming.each { |row| render.loras.create!(**row) }
    end

    def lora_row(lora, fallback_position)
      attrs = lora.to_h.symbolize_keys

      { name: attrs[:name].to_s, layer: (attrs[:layer] || "base").to_s,
        strength: attrs[:strength], enabled: attrs[:enabled],
        position: attrs[:position] || fallback_position }
    end

    # Comparison key: a slot is (layer, name), ordered deterministically, with strength
    # normalised to a float so a DB decimal and a caller's float are the same fact.
    def canonical_loras(rows)
      rows.map { |row| row.merge(strength: row[:strength]&.to_f) }
          .sort_by { |row| [ row[:layer].to_s, row[:name].to_s ] }
    end
  end
end
