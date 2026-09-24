class Vote < ApplicationRecord
  belongs_to :winner, class_name: "ImageCandidate"
  belongs_to :loser, class_name: "ImageCandidate"

  validates :winner_id, presence: true
  validates :loser_id, presence: true
  validates :winner_id, uniqueness: { scope: :loser_id }
  validate :winner_and_loser_must_be_different

  private

  def winner_and_loser_must_be_different
    if winner_id == loser_id
      errors.add(:base, "Winner and loser must be different")
    end
  end
end
