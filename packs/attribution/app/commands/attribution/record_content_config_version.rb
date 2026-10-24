# frozen_string_literal: true

module Attribution
  # The ONE writer for content config versions: the pinned axes, the named prompt parts and the
  # LoRA set, written together and addressed by the digest of their own content.
  #
  # WHY ONE WRITER. A version's whole value is that a render can point at it and be believed.
  # If two paths could build one, the digest would be a convention rather than a fact, and the
  # one-axis query would silently compare two things that are not the same kind of object.
  #
  # IDEMPOTENT BY CONTENT, NOT BY ARGUMENT. The digest is derived from the pins, so the same
  # config resolves to the SAME row however often it is recorded -- a retried tick or a second
  # render of the same scene does not fork a new version, and the caller
  # never has to remember an id. A changed pin computes a different digest and therefore
  # writes a NEW row, which is the whole immutability story in one line.
  #
  # WHAT IT REFUSES, each refusal mechanical rather than a note in a document:
  #   * an assembled prompt. The parts must be NAMED; a String is rejected. A string cannot be
  #     varied, and parsing one back into parts is a guess dressed as a record.
  #   * an empty part set. A config created now must name its axes; an unnamed config is
  #     indistinguishable from the pre-spine corpus.
  #
  # The parts arrive AS ARGUMENTS from whatever is editing the config -- never extracted from
  # the graph or from an assembled prompt afterwards, for the same reason the render's parts
  # are handed over by their creator.
  class RecordContentConfigVersion < ApplicationCommand
    requires :prompt_parts
    allows :content_pillar, :pipeline_step, :wardrobe_level, :checkpoint, :negative_prompt,
           :workflow_sha256, :workflow_path, :loras

    returns :version

    def call
      parts = validated_parts
      loras = Array(context.loras)

      context.version = find_version(parts, loras) || create_version(parts, loras)
    end

    # The write is a single transaction, so a failure leaves no half-written version. Nothing
    # is destroyed on the way out: versions are append-only, and a rollback must not delete a
    # row some earlier render may already reference.
    def rollback; end

    private

    def pins(parts, loras)
      {
        content_pillar_id: context.content_pillar&.id,
        wardrobe_level: context.wardrobe_level,
        checkpoint: context.checkpoint,
        negative_prompt: context.negative_prompt,
        workflow_sha256: context.workflow_sha256,
        prompt_parts: parts.each_part.map { |name, text, _position| [ name, text ] },
        loras: loras.map do |lora|
          attrs = lora.to_h.symbolize_keys
          attrs.slice(:layer, :name, :strength, :enabled)
        end
      }
    end

    def digest(parts, loras)
      Attribution::ContentConfigVersion.digest_for(pins(parts, loras))
    end

    def find_version(parts, loras)
      Attribution::ContentConfigVersion.find_by(digest: digest(parts, loras))
    end

    def create_version(parts, loras)
      ActiveRecord::Base.transaction do
        version = Attribution::ContentConfigVersion.new(
          content_pillar: context.content_pillar,
          pipeline_step: context.pipeline_step,
          wardrobe_level: context.wardrobe_level,
          checkpoint: context.checkpoint,
          negative_prompt: context.negative_prompt,
          # Provenance, not identity: where the graph was read from. The sha is what the graph
          # IS, so the path is recorded but is not part of the digest.
          workflow_sha256: context.workflow_sha256,
          workflow_path: context.workflow_path
        )

        parts.each_part do |name, text, position|
          version.prompt_parts.build(name: name, text: text, position: position)
        end
        loras.each_with_index do |lora, position|
          version.loras.build(**lora_attributes(lora, position))
        end

        version.save!

        context.version = version
      end
    rescue ActiveRecord::RecordNotUnique
      # Two creators computing the same digest at the same instant: the config is identical by
      # definition, so the row the other one wrote IS this version.
      Attribution::ContentConfigVersion.find_by!(digest: digest(parts, loras))
    end

    def lora_attributes(lora, fallback_position)
      attrs = lora.to_h.symbolize_keys

      { name: attrs[:name].to_s, layer: (attrs[:layer] || "base").to_s,
        strength: attrs[:strength], enabled: attrs[:enabled],
        position: attrs[:position] || fallback_position }
    end

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

      stop_and_fail!("prompt_parts is empty: a config created now must name its prompt parts") if parts.empty?

      parts
    end
  end
end
