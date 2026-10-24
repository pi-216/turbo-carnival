# frozen_string_literal: true

module Attribution
  # One LoRA slot OF A CONFIG VERSION: which file, which layer it drives, at what strength,
  # and whether it was on -- the config-side twin of `Attribution::Lora`.
  #
  # An OFF slot is recorded rather than omitted, and that is load-bearing for the digest: the
  # same file listed at strength 0.75 with `enabled: false` is a DIFFERENT config from the
  # same file not being in the graph at all, and only the recorded flag tells them apart. An
  # edit to that flag has to produce a new version, not a quiet change of meaning.
  #
  # `strength` and `enabled` stay nullable: where nobody recorded them, the answer is UNKNOWN,
  # not 0 or false.
  class ContentConfigVersionLora < ApplicationRecord
    self.table_name = "content_config_version_loras"

    belongs_to :content_config_version, class_name: "Attribution::ContentConfigVersion",
               inverse_of: :loras

    validates :name, presence: true, uniqueness: { scope: [ :content_config_version_id, :layer ] }
    validates :layer, presence: true
    validates :strength, numericality: true, allow_nil: true
    validates :enabled, inclusion: { in: [ true, false ] }, allow_nil: true
    validates :position, presence: true,
                         numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  end
end
