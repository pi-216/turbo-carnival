# frozen_string_literal: true

module Attribution
  # A measurement OF a render, keyed to the assessor that produced it.
  #
  # The assessor is (model + version), not a bare name: two versions of the same assessor are
  # two genuinely different measurements, and letting v2 overwrite v1's number would destroy
  # the comparison the version column exists to make possible.
  #
  # A metric that was not measured is stored as NULL, never as 0. A measured zero and an
  # absent measurement are different facts, and collapsing them manufactures data.
  class Assessment < ApplicationRecord
    belongs_to :render, class_name: "Attribution::Render", inverse_of: :assessments

    validates :assessor_model, :assessor_version, :metric, presence: true
    validates :metric, uniqueness: { scope: [ :render_id, :assessor_model, :assessor_version ] }
    validates :value, numericality: true, allow_nil: true
  end
end
