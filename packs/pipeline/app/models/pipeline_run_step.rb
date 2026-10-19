class PipelineRunStep < ApplicationRecord
  belongs_to :pipeline_run, touch: true
  belongs_to :pipeline_step, touch: true

  validates :top_k_count, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :approved, inclusion: { in: [ true, false ] }
  validate :approved_at_required_if_approved

  def top_k_candidates
    ImageCandidate
      .where(
        pipeline_step: pipeline_step,
        pipeline_run: pipeline_run,
        status: 'active'
      )
      .order(elo_score: :desc)
      .limit(top_k_count)
  end

  private

  def approved_at_required_if_approved
    if approved? && approved_at.nil?
      errors.add(:approved_at, "must be set when approved is true")
    end
  end
end
