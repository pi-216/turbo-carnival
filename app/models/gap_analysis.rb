class GapAnalysis < ApplicationRecord
  belongs_to :persona
  has_many :content_suggestions, dependent: :destroy

  validates :analyzed_at, presence: true

  scope :recent, -> { order(analyzed_at: :desc) }
  scope :latest_for_persona, ->(persona) { where(persona: persona).order(analyzed_at: :desc).first }
end
