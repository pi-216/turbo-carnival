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

    # The CONFIG this render ran under (#40). Optional because a render that predates the
    # spine has UNKNOWN attribution -- and "unknown" is a fact about the record, not something
    # a default version may paper over. A render created NOW must reference one; that rule is
    # enforced by the writer (`RecordRender`), not by this association, so an existing row can
    # still be backfilled honestly.
    belongs_to :content_config_version, class_name: "Attribution::ContentConfigVersion",
               optional: true, inverse_of: :renders

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

    # The names whose prompt text differs between this render and `other`, read from rows
    # only -- no assembled prompt is compared, because there is not one to compare.
    #
    # A name carried by one render and not the other COUNTS AS DIFFERING: an absent part is
    # not the same fact as a written one, so silence must not read as agreement.
    def varying_parts(other)
      mine = prompt_parts.pluck(:name, :text).to_h
      theirs = other.prompt_parts.pluck(:name, :text).to_h

      (mine.keys | theirs.keys).reject { |name| mine[name] == theirs[name] }.sort
    end

    # The prompt-level analogue of the render-graph leaf diff (#38 criterion 1): true when
    # this render and `other` carry the SAME set of part names and exactly one of those
    # names holds different text. A pair admitted here differs in one addressable axis and
    # nothing else, which is what makes a one-part comparison a comparison.
    def differs_in_exactly_one_part?(other)
      return false unless prompt_parts.pluck(:name).sort == other.prompt_parts.pluck(:name).sort

      varying_parts(other).length == 1
    end

    # Renders that differ from `render` in EXACTLY ONE named prompt part -- the same set of
    # names, exactly one text changed, and nothing else about the prompt different.
    #
    # This is a query over rows, not a scan in Ruby: the anchor's parts are left-joined onto
    # every candidate render and the differences are counted, so "differing in exactly one
    # part" is decided by the database. The count of parts is compared too, which is what
    # excludes a render that is simply MISSING a name (a missing part is absent, never a
    # match).
    def self.varying_one_part_from(render)
      anchor = render.id
      part_count = render.reload.prompt_parts.count
      return none if part_count.zero?

      joins("LEFT JOIN render_prompt_parts part ON part.render_id = renders.id")
        .joins(sanitize_sql_array(
                 [ "LEFT JOIN render_prompt_parts anchor_part ON anchor_part.name = part.name " \
                   "AND anchor_part.render_id = ?", anchor ]
               ))
        .where.not(id: anchor)
        .group("renders.id")
        .having("COUNT(*) = ?", part_count)
        .having("COUNT(*) FILTER (WHERE anchor_part.id IS NULL) = 0")
        .having("COUNT(*) FILTER (WHERE anchor_part.text IS DISTINCT FROM part.text) = 1")
    end

    # The full input set, from columns and rows only -- no blob is parsed to answer it.
    #
    # `content_config_version` is the ADDRESS of the config this render ran under (#40): the
    # digest, not the id, so two rows that name the same config are visibly the same config
    # without a second lookup.
    def inputs
      {
        content_config_version: content_config_version&.digest,
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
