# frozen_string_literal: true

module Attribution
  # A named prompt part -- the addressable unit of a prompt.
  #
  # The graph assembles its text from several blocks (identity, scene, wardrobe, ...), and the
  # assembled string is an OUTCOME: it cannot be varied, only re-guessed. Recording the parts
  # by name is what makes "two renders differing in exactly one part" a query.
  #
  # The negative is NOT a part. It is a single scalar per render, so it is a `renders` column,
  # and RESERVED_NAMES keeps that true as writers are added -- one fact, one home.
  class PromptPart < ApplicationRecord
    self.table_name = "render_prompt_parts"

    # The canonical vocabulary of part names (#38). A part's NAME *is* the axis, so the
    # vocabulary is closed and lives here, in one place: two renders are only comparable
    # when they name the same things, and a name invented at one call site would fragment
    # the one-axis query. Adding an axis is a deliberate edit to this list, never a new
    # string in a worker.
    #
    # These are the parts the current graph is assembled from: the identity block (node 88)
    # and the scene text, with wardrobe split out of the scene so it can be varied on its
    # own. `negative` is deliberately NOT here -- see RESERVED_NAMES.
    NAMES = %w[identity scene wardrobe].freeze

    NAME_FORMAT = /\A[a-z][a-z0-9_]*\z/

    RESERVED_NAMES = %w[negative].freeze

    belongs_to :render, class_name: "Attribution::Render", inverse_of: :prompt_parts

    before_validation :compute_text_sha256

    validates :name, presence: true,
                     uniqueness: { scope: :render_id },
                     format: { with: NAME_FORMAT,
                               message: "must be a lowercase snake_case token" },
                     inclusion: { in: NAMES,
                                  message: "is not a known prompt part (add it to " \
                                           "Attribution::PromptPart::NAMES to make it an axis)" },
                     exclusion: { in: RESERVED_NAMES,
                                  message: "is reserved (the negative prompt is a column on the render)" }
    validates :position, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

    private

    # Derived, never authored: a part's digest is what lets a later reader tell "same text,
    # different name" from "same name, changed text". A part with no text has no digest.
    def compute_text_sha256
      self.text_sha256 = text.nil? ? nil : Digest::SHA256.hexdigest(text)
    end
  end
end
