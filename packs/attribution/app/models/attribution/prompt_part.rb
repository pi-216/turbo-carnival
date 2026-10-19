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

    RESERVED_NAMES = %w[negative].freeze

    belongs_to :render, class_name: "Attribution::Render", inverse_of: :prompt_parts

    before_validation :compute_text_sha256

    validates :name, presence: true,
                     uniqueness: { scope: :render_id },
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
