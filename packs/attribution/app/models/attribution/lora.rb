# frozen_string_literal: true

module Attribution
  # One LoRA slot on a render: which file, which layer it drives, at what strength, and
  # whether it was on.
  #
  # An OFF slot is recorded rather than omitted. Measured in this repo, an off LoRA's strength
  # is INERT -- but "off at 0.75" and "not in the graph at all" are different setups, and only
  # the recorded flag tells them apart.
  #
  # `strength` and `enabled` stay nullable: where nobody recorded them, the answer is UNKNOWN,
  # not 0 or false.
  class Lora < ApplicationRecord
    self.table_name = "render_loras"

    belongs_to :render, class_name: "Attribution::Render", inverse_of: :loras

    validates :name, presence: true, uniqueness: { scope: [ :render_id, :layer ] }
    validates :layer, presence: true
    validates :strength, numericality: true, allow_nil: true
    validates :enabled, inclusion: { in: [ true, false ] }, allow_nil: true
    validates :position, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  end
end
