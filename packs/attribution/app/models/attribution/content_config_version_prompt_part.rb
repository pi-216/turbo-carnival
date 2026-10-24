# frozen_string_literal: true

module Attribution
  # One named prompt part OF A CONFIG VERSION -- the input side of `Attribution::PromptPart`.
  #
  # WHY A SECOND TABLE RATHER THAN A POINTER AT THE RENDER'S PARTS. A version is created by
  # whoever edits the config, and a render records what a run executed; sharing one row would
  # make the config depend on a render existing, and would let a render's write redefine the
  # config it claims to have run under. Two facts, two homes -- and the digest covers the
  # version's copy, which is what makes a text change a NEW version.
  #
  # The VOCABULARY is not duplicated: the name list, its format and its reserved words live on
  # `Attribution::PromptPart`, because two homes for one closed vocabulary is exactly how the
  # one-axis query fragments.
  class ContentConfigVersionPromptPart < ApplicationRecord
    self.table_name = "content_config_version_prompt_parts"

    belongs_to :content_config_version, class_name: "Attribution::ContentConfigVersion",
               inverse_of: :prompt_parts

    before_validation :compute_text_sha256

    validates :name, presence: true,
                     uniqueness: { scope: :content_config_version_id },
                     format: { with: PromptPart::NAME_FORMAT,
                               message: "must be a lowercase snake_case token" },
                     inclusion: { in: PromptPart::NAMES,
                                  message: "is not a known prompt part (add it to " \
                                           "Attribution::PromptPart::NAMES to make it an axis)" },
                     exclusion: { in: PromptPart::RESERVED_NAMES,
                                  message: "is reserved (the negative prompt is a column on the config version)" }
    validates :position, presence: true,
                         numericality: { only_integer: true, greater_than_or_equal_to: 0 }

    private

    # Derived, never authored: the digest of a part's text is what lets a reader tell "same
    # text, different name" from "same name, changed text". A part with no text has no digest.
    def compute_text_sha256
      self.text_sha256 = text.nil? ? nil : Digest::SHA256.hexdigest(text)
    end
  end
end
