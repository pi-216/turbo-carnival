class ContentSuggestion < ApplicationRecord
  belongs_to :gap_analysis
  belongs_to :content_pillar

  validates :title, :description, presence: true
  validates :status, inclusion: { in: %w[pending used rejected] }

  scope :pending, -> { where(status: "pending") }
  scope :used, -> { where(status: "used") }
  scope :rejected, -> { where(status: "rejected") }

  # Virtual attribute for easier form handling
  def prompt
    prompt_data&.dig("prompt")
  end

  def prompt=(value)
    self.prompt_data ||= {}
    self.prompt_data["prompt"] = value
  end

  def mark_as_used!
    update!(status: "used", used_at: Time.current)
  end

  def mark_as_rejected!
    update!(status: "rejected")
  end
end
