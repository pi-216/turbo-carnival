# frozen_string_literal: true

class ContentPillar < ApplicationRecord
  belongs_to :persona
  has_many :photos, class_name: 'ContentPillars::Photo', foreign_key: :content_pillar_id, dependent: :restrict_with_error

  validates :name, presence: true, uniqueness: { scope: :persona_id }
  validates :weight, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
  validates :priority, numericality: { greater_than_or_equal_to: 1, less_than_or_equal_to: 5 }
  validate :end_date_after_start_date
  validate :total_weight_within_limit
  validate :wardrobe_level_within_scale

  # PRD 0007 A2 (#105): the pillar's rung on the wardrobe axis (1-based). NULL
  # is legal (unconfigured -> the render falls back to the axis floor). The
  # data layer validates the SCALE only; the dynamic "current validated tier"
  # ceiling is enforced by the growth layer (Growth::PersonaEvolution lever +
  # ContentPillars::WardrobeAxis#effective_level) so the render and the audit
  # record are always bounded by the tier.

  scope :active, -> { where(active: true) }
  scope :current, lambda {
    active
      .where('start_date IS NULL OR start_date <= ?', Date.current)
      .where('end_date IS NULL OR end_date >= ?', Date.current)
  }
  scope :by_priority, -> { order(priority: :desc, weight: :desc) }

  def current?
    return false unless active?
    return true if start_date.nil? && end_date.nil?
    return false if start_date && start_date > Date.current
    return false if end_date && end_date < Date.current
    true
  end

  def expired?
    end_date.present? && end_date < Date.current
  end

  # Alias for caption generation compatibility (was cluster.ai_prompt)
  def ai_prompt
    guidelines || description
  end

  private

  # The pillar's wardrobe rung must be on the scale (1..MAX_LEVEL). NULL is
  # allowed (unconfigured). The dynamic validated-tier ceiling is NOT enforced
  # here — see the class comment on `wardrobe_level`.
  def wardrobe_level_within_scale
    return if wardrobe_level.nil?
    return if ContentPillars::WardrobeAxis.on_scale?(wardrobe_level)

    errors.add(:wardrobe_level,
               "must be #{ContentPillars::WardrobeAxis::MIN_LEVEL}..#{ContentPillars::WardrobeAxis::MAX_LEVEL}")
  end

  def end_date_after_start_date
    return if start_date.nil? || end_date.nil?
    return if end_date > start_date

    errors.add(:end_date, 'must be after start date')
  end

  def total_weight_within_limit
    return unless persona

    total = persona.content_pillars.active.where.not(id: id).sum(:weight) + (weight || 0)
    return if total <= 100

    errors.add(:weight, "total weight for persona would exceed 100% (current: #{total}%)")
  end
end
