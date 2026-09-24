class ImageCandidate < ApplicationRecord
  belongs_to :pipeline_step, touch: true
  belongs_to :pipeline_run, optional: true, touch: true
  belongs_to :parent, class_name: "ImageCandidate", optional: true, counter_cache: :child_count
  has_many :children, class_name: "ImageCandidate", foreign_key: :parent_id, dependent: :nullify
  has_one :photo, class_name: "ContentPillars::Photo", dependent: :destroy

  validates :elo_score, numericality: { only_integer: true }
  validates :status, inclusion: { in: %w[active rejected] }
  validates :child_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :vote_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  # Broadcast updates to the run when candidates change
  after_create_commit :broadcast_run_update
  after_update_commit :broadcast_run_update
  after_destroy_commit :broadcast_run_update

  state_machine :status, initial: :active do
    state :active
    state :rejected

    event :reject do
      transition active: :rejected
    end

    after_transition active: :rejected do |candidate, transition|
      # Decrement parent's child_count when rejecting a child
      if candidate.parent
        candidate.parent.decrement!(:child_count)
      end

      # Broadcast run update after rejection
      candidate.broadcast_run_update
    end
  end

  scope :active, -> { where(status: "active") }
  scope :winners, -> { where(winner: true) }
  scope :not_winners, -> { where(winner: false) }

  def mark_as_winner!
    transaction do
      # Unmark other candidates in the same run
      pipeline_run.image_candidates.where.not(id: id).update_all(winner: false, winner_at: nil)

      # Mark this one
      update!(winner: true, winner_at: Time.current)

      # Create Photo record if run belongs to a content pillar
      create_photo_record if pipeline_run&.content_pillar_id.present?
    end
  end

  def unmark_as_winner!
    transaction do
      update!(winner: false, winner_at: nil)

      # Remove the Photo record if it exists
      remove_photo_record if pipeline_run&.content_pillar_id.present?
    end
  end

  def broadcast_run_update
    pipeline_run&.broadcast_refresh
  end

  def calculate_elo_change(opponent, won)
    k_factor = 32
    expected_score = 1.0 / (1.0 + 10.0**((opponent.elo_score - elo_score) / 400.0))
    actual_score = won ? 1.0 : 0.0
    (k_factor * (actual_score - expected_score)).round
  end

  private

  def create_photo_record
    return unless image_path.present?
    return if photo.present? # Already has a photo record
    return unless pipeline_run.content_pillar_id.present?

    pillar = ContentPillar.find(pipeline_run.content_pillar_id)

    created_photo = ContentPillars::Photo.create!(
      persona: pillar.persona,
      content_pillar: pillar,
      path: image_path,
      image_candidate: self
    )

    # Attach the image file to ActiveStorage
    if File.exist?(image_path)
      created_photo.image.attach(
        io: File.open(image_path),
        filename: File.basename(image_path),
        content_type: 'image/png'
      )
    end

    created_photo
  rescue => e
    Rails.logger.error "Failed to create Photo record: #{e.message}"
    raise
  end

  def photo_record_exists?
    photo.present?
  end

  def remove_photo_record
    photo&.destroy
  rescue => e
    Rails.logger.error "Failed to remove Photo record: #{e.message}"
    raise
  end

  def self.unvoted_pairs(pipeline_step)
    candidates = where(pipeline_step: pipeline_step, status: "active")
                  .order(:vote_count, :id)
                  .to_a

    return [] if candidates.empty?

    # Get all existing votes for these candidates
    candidate_ids = candidates.map(&:id)
    existing_votes = Vote.where(winner_id: candidate_ids, loser_id: candidate_ids)
                         .pluck(:winner_id, :loser_id)
                         .to_set

    # Also check reverse pairs (loser, winner) since either direction counts as voted
    reverse_votes = existing_votes.map { |w, l| [ l, w ] }.to_set
    all_voted_pairs = existing_votes + reverse_votes

    # Generate all possible pairs
    all_pairs = candidates.combination(2).to_a

    # Filter out pairs that have already been voted on
    unvoted = all_pairs.reject do |a, b|
      all_voted_pairs.include?([ a.id, b.id ])
    end

    # Sort pairs by the sum of vote counts (prioritize pairs with lower total votes)
    unvoted.sort_by! { |a, b| a.vote_count + b.vote_count }

    unvoted
  end
end
