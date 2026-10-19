# frozen_string_literal: true

class ContentPillar < ApplicationRecord
  belongs_to :persona
  has_many :photos, class_name: 'ContentPillars::Photo', foreign_key: :content_pillar_id, dependent: :restrict_with_error

  validates :name, presence: true, uniqueness: { scope: :persona_id }
  validates :weight, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
  validates :priority, numericality: { greater_than_or_equal_to: 1, less_than_or_equal_to: 5 }
  validate :end_date_after_start_date
  validate :total_weight_within_limit

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
