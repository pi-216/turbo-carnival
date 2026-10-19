# frozen_string_literal: true

module Attribution
  # One row per rendering attempt, and the input set that produced it.
  #
  # Every axis is a real column (or a child row) instead of a key inside
  # `pipeline_runs.variables`. The blob could not be grouped, filtered or joined, and the
  # attribution question is a query, not an anecdote.
  #
  # There is deliberately NO assembled-prompt column. The prompt is stored as named parts
  # (`Attribution::PromptPart`) because a part can be varied and an assembled string cannot.
  # Do not re-introduce one by parsing the parts back together -- reconstructed is not
  # recorded, and a guess would silently poison every later comparison.
  #
  # Every input column is nullable, and that is load-bearing: the corpus holds hundreds of
  # posts rendered before any of this existed. An absent axis means UNKNOWN, which is a fact
  # about the record. Defaulting one to 0 would invent a measurement.
  class Render < ApplicationRecord
    self.table_name = "renders"

    belongs_to :asset, class_name: "Attribution::Asset", optional: true, inverse_of: :renders
    belongs_to :pipeline_run, optional: true

    # The candidate this render produced -- i.e. the image that was actually published.
    # Declared on THIS side because the reverse (ImageCandidate -> render) would make
    # packs/pipeline reference packs/attribution while attribution already depends on
    # pipeline, which is a cycle. Growth::RenderReach walks it from here.
    belongs_to :image_candidate, optional: true

    has_many :prompt_parts, -> { order(:position, :name) },
             class_name: "Attribution::PromptPart", dependent: :destroy, inverse_of: :render
    has_many :loras, -> { order(:layer, :position, :name) },
             class_name: "Attribution::Lora", dependent: :destroy, inverse_of: :render
    has_many :assessments, class_name: "Attribution::Assessment", dependent: :destroy, inverse_of: :render

    validates :seed, numericality: { only_integer: true }, allow_nil: true
    validates :steps, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
    validates :cfg, numericality: { greater_than: 0 }, allow_nil: true
    validates :denoise, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
    validates :width, :height, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true

    # Stored as two integer columns rather than a "832x1216" string so the axis stays
    # queryable; this is the readable form.
    def resolution
      return nil if width.nil? || height.nil?

      "#{width}x#{height}"
    end

    # The full input set, from columns and rows only -- no blob is parsed to answer it.
    def inputs
      {
        checkpoint: checkpoint,
        seed: seed,
        sampler: sampler,
        scheduler: scheduler,
        steps: steps,
        cfg: cfg,
        denoise: denoise,
        resolution: resolution,
        negative: negative_prompt,
        workflow_sha256: workflow_sha256,
        workflow_path: workflow_path,
        prompt_parts: prompt_parts.each_with_object({}) { |part, parts| parts[part.name] = part.text },
        loras: loras.map do |lora|
          { name: lora.name, layer: lora.layer, strength: lora.strength, enabled: lora.enabled }
        end
      }
    end
  end
end
