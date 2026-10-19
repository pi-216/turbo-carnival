class PipelineRun < ApplicationRecord
  include Turbo::Broadcastable

  belongs_to :pipeline, touch: true
  belongs_to :persona, optional: true
  belongs_to :content_pillar, class_name: 'ContentPillar', optional: true
  has_many :image_candidates, dependent: :destroy
  has_many :pipeline_run_steps, dependent: :destroy

  validates :pipeline, presence: true
  validates :status, inclusion: { in: %w[pending running completed failed] }

  after_create :create_pipeline_run_steps
  after_update_commit :broadcast_run_update
  after_update :link_winner_to_pillar_if_completed, if: :saved_change_to_status?

  def step_approved?(step)
    pipeline_run_steps.find_by(pipeline_step: step)&.approved? || false
  end

  def approve_step!(step, top_k: 3)
    prs = pipeline_run_steps.find_or_create_by(pipeline_step: step)
    raise "Step already approved" if prs.approved?

    prs.update!(
      approved: true,
      approved_at: Time.current,
      top_k_count: top_k
    )
  end

  def broadcast_run_update
    broadcast_replace_to "runs",
      partial: "runs/run_card",
      locals: { run: self },
      target: "run_#{id}"
  end

  def broadcast_refresh
    broadcast_replace_to "runs",
      partial: "runs/run_card",
      locals: { run: self },
      target: "run_#{id}"
  end

  private

  def create_pipeline_run_steps
    pipeline.pipeline_steps.each do |step|
      pipeline_run_steps.create!(
        pipeline_step: step,
        approved: false,
        approved_at: nil,
        top_k_count: JobOrchestrationConfig.max_children_per_node
      )
    end
  end

  def link_winner_to_pillar_if_completed
    return unless status == 'completed'
    return unless content_pillar_id.present?

    ContentPillars::LinkWinnerToPillar.call(self)
    link_to_awaiting_posts
  rescue StandardError => e
    Rails.logger.error("Failed to auto-link winner for run #{id}: #{e.message}")
    # Don't fail the run completion, just log the error
  end

  def link_to_awaiting_posts
    # Find all posts waiting for this pipeline run
    awaiting_posts = Scheduling::Post.where(
      pipeline_run_id: id,
      photo_id: nil
    )

    return if awaiting_posts.empty?

    # Find the winner image
    winner = image_candidates.find_by(winner: true)
    return unless winner&.photo

    # Link and transition
    awaiting_posts.each do |post|
      post.update!(photo: winner.photo)

      # Auto-schedule LLM campaigns, manual review for others
      if post.content_suggestion_id.present? && post.scheduled_at.present?
        post.schedule! if post.may_schedule?
      else
        post.image_ready! if post.may_image_ready?
      end
    end

    Rails.logger.info("Linked #{awaiting_posts.count} posts to winner #{winner.id}")
  end
end
