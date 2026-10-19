# frozen_string_literal: true

class Persona < ApplicationRecord
  has_many :content_pillars, dependent: :restrict_with_error
  has_many :photos, through: :content_pillars, class_name: 'ContentPillars::Photo'
  has_many :gap_analyses, dependent: :destroy

  validates :name, presence: true, uniqueness: true

  def caption_config
    return nil if self[:caption_config].nil? || self[:caption_config].empty?
    @caption_config ||= Personas::CaptionConfig.from_hash(self[:caption_config])
  end

  def caption_config=(value)
    config = value.is_a?(Personas::CaptionConfig) ? value : Personas::CaptionConfig.new(value)
    raise ArgumentError, config.errors.join(', ') unless config.valid?

    self[:caption_config] = config.to_hash
    @caption_config = config
  end

  def hashtag_strategy
    return nil if self[:hashtag_strategy].nil? || self[:hashtag_strategy].empty?
    @hashtag_strategy ||= Personas::HashtagStrategy.from_hash(self[:hashtag_strategy])
  end

  def hashtag_strategy=(value)
    strategy = value.is_a?(Personas::HashtagStrategy) ? value : Personas::HashtagStrategy.new(value)
    raise ArgumentError, strategy.errors.join(', ') unless strategy.valid?

    self[:hashtag_strategy] = strategy.to_hash
    @hashtag_strategy = strategy
  end
end
