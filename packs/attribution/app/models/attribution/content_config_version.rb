# frozen_string_literal: true

module Attribution
  # The content configuration as an IMMUTABLE VERSION -- the address a metric shift has.
  #
  # WHY THIS EXISTS (#40 / PRD 0002, plan item W1.2). A render records what ONE render
  # executed; it cannot say which version of the CONFIG it ran under, because the config is
  # not a thing in this database: it is spread across `content_pillars` rows (weight, wardrobe
  # rung), the scene bank in `Growth::PillarPrompt`, and the graph in
  # `pipeline_steps.comfy_workflow_json`. So "the config changed and reach moved" has no
  # address, and two render sets cannot be compared without a human reconstructing which
  # renders belonged to which change.
  #
  # WHAT A VERSION PINS: the pillar it configures, the wardrobe rung, the checkpoint, the LoRA
  # set (with strengths and on/off), the negative, the workflow sha, and the prompt parts.
  # Those are exactly the axes an edit would move, which is why they are what the digest
  # covers.
  #
  # WHAT IT DELIBERATELY DOES NOT PIN: the seed, the produced asset, and the timestamp. Those
  # vary per RENDER, not per config -- one version legitimately covers hundreds of renders.
  # Pinning them here would make every render its own version, which is the reverse of the
  # point: the version is what renders SHARE, and it is what makes "the config that earned
  # this reach" a query instead of an anecdote.
  #
  # IMMUTABLE IN THREE LAYERS, because a version you can edit destroys the attribution of
  # every render that referenced it, retroactively (#40's red line -- the same failure the
  # DB-only workflow column had):
  #   1. the digest is DERIVED from the pins (`before_validation`), never authored, so a
  #      version's identity IS its content and a changed pin is a different row by
  #      construction;
  #   2. `#readonly?` is true for a persisted row, so every ActiveRecord write path -- save,
  #      update, update_columns, destroy -- raises instead of mutating;
  #   3. a BEFORE UPDATE OR DELETE trigger
  #      (`db/triggers/content_config_version_immutability.sql`) refuses the raw-SQL bypasses
  #      (`update_all`, `delete_all`, a future migration), which layers 1 and 2 cannot see.
  #
  # Creating one is `Attribution::RecordContentConfigVersion`'s job -- the single writer, and
  # the only path that knows the idempotence rule (same pins -> the same row, found by digest).
  class ContentConfigVersion < ApplicationRecord
    self.table_name = "content_config_versions"

    DIGEST_FORMAT = /\A[0-9a-f]{64}\z/

    belongs_to :content_pillar, optional: true
    belongs_to :pipeline_step, optional: true

    has_many :prompt_parts, -> { order(:position, :name) },
             class_name: "Attribution::ContentConfigVersionPromptPart",
             dependent: :restrict_with_error, inverse_of: :content_config_version
    has_many :loras, -> { order(:layer, :position, :name) },
             class_name: "Attribution::ContentConfigVersionLora",
             dependent: :restrict_with_error, inverse_of: :content_config_version

    # The renders that ran under this config. `restrict_with_error`, not `nullify`: a version
    # that vanished would silently re-label its renders as unattributed, which is the
    # retroactive destruction this class exists to prevent.
    has_many :renders, class_name: "Attribution::Render",
             dependent: :restrict_with_error, inverse_of: :content_config_version

    before_validation :compute_digest

    validates :digest, presence: true, uniqueness: true, format: { with: DIGEST_FORMAT }
    # The rung the config was built for. Its SCALE lives in the pillar's axis
    # (`ContentPillars::WardrobeAxis`), not here: a second copy of the ladder is how two homes
    # for one fact start disagreeing. Nullable = UNKNOWN, like every other axis.
    validates :wardrobe_level, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true

    # The pins, as the canonical value the digest is taken over. Order is canonicalised
    # (parts by name, LoRAs by layer+name), so writing the same parts in a different ORDER is
    # the same config -- position is for reading, not for identity.
    def self.pins_for(pins)
      parts = Array(pins[:prompt_parts]).map do |name, text|
        { "name" => name.to_s, "text" => text }
      end.sort_by { |part| part["name"] }

      loras = Array(pins[:loras]).map do |lora|
        attrs = lora.to_h.symbolize_keys

        { "enabled" => attrs[:enabled], "layer" => (attrs[:layer] || "base").to_s,
          "name" => attrs[:name].to_s, "strength" => normalize_strength(attrs[:strength]) }
      end.sort_by { |row| [ row["layer"], row["name"] ] }

      {
        "checkpoint" => pins[:checkpoint],
        "content_pillar_id" => pins[:content_pillar_id],
        "loras" => loras,
        "negative_prompt" => pins[:negative_prompt],
        "prompt_parts" => parts,
        "wardrobe_level" => pins[:wardrobe_level],
        "workflow_sha256" => pins[:workflow_sha256]
      }
    end

    # A version's identity: sha256 over the canonical pins. Derived, never authored -- which
    # is what makes "editing the config creates a NEW version" structural rather than a rule
    # somebody has to remember.
    def self.digest_for(pins)
      Digest::SHA256.hexdigest(JSON.generate(canonicalize(pins_for(pins))))
    end

    # Sorts every hash by key, recursively, so the serialisation is stable however the caller
    # built it. Array order is preserved -- it is already canonical by then.
    def self.canonicalize(value)
      case value
      when Hash then value.map { |key, nested| [ key.to_s, canonicalize(nested) ] }.sort_by(&:first).to_h
      when Array then value.map { |nested| canonicalize(nested) }
      else value
      end
    end

    # A DB decimal and a caller's float are the same fact, so strength is compared as a
    # normalised float -- the same rule `RecordRender` uses for its LoRA set.
    def self.normalize_strength(value)
      value.nil? ? nil : value.to_f.to_s
    end

    # Every ActiveRecord write to a persisted version is refused. `save`/`update` raise
    # ReadOnlyRecord; `update_columns` and `destroy` go through the same guard.
    def readonly?
      persisted?
    end

    # The pins as recorded, in the shape `pins_for` accepts -- so `#recomputed_digest` can
    # re-derive this row's identity from its own columns and children.
    def pins
      {
        content_pillar_id: content_pillar_id,
        wardrobe_level: wardrobe_level,
        checkpoint: checkpoint,
        negative_prompt: negative_prompt,
        workflow_sha256: workflow_sha256,
        prompt_parts: prompt_parts.map { |part| [ part.name, part.text ] },
        loras: loras.map do |lora|
          { layer: lora.layer, name: lora.name, strength: lora.strength, enabled: lora.enabled }
        end
      }
    end

    # The tamper check: does this row still say what its content says it says? It is the
    # reconciliation between layer 1 (derived identity) and layers 2/3 (refused writes), and
    # it is the thing to run if a version is ever suspected of having been edited by hand.
    def recomputed_digest
      self.class.digest_for(pins)
    end

    def consistent?
      digest == recomputed_digest
    end

    private

    # Derived on write so an authored digest cannot disagree with the pins it names. Skipped
    # for a persisted row, which is not writable anyway -- recomputing there would only
    # pretend an edit had been applied.
    def compute_digest
      return if persisted?

      self.digest = self.class.digest_for(
        content_pillar_id: content_pillar_id,
        wardrobe_level: wardrobe_level,
        checkpoint: checkpoint,
        negative_prompt: negative_prompt,
        workflow_sha256: workflow_sha256,
        prompt_parts: prompt_parts.map { |part| [ part.name, part.text ] },
        loras: loras.map do |lora|
          { layer: lora.layer, name: lora.name, strength: lora.strength, enabled: lora.enabled }
        end
      )
    end
  end
end
