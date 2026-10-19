# frozen_string_literal: true

module Personas
  class CaptionConfig
    attr_reader :tone, :style, :voice, :max_length, :errors

    def initialize(attributes = {})
      @tone = attributes[:tone] || attributes['tone']
      @style = attributes[:style] || attributes['style']
      @voice = attributes[:voice] || attributes['voice']
      @max_length = attributes[:max_length] || attributes['max_length']
      @errors = []
      validate
    end

    def valid?
      @errors.empty?
    end

    def to_hash
      {
        tone: @tone,
        style: @style,
        voice: @voice,
        max_length: @max_length
      }.compact
    end

    def self.from_hash(hash)
      new(hash)
    end

    private

    def validate
      # Optional: Add validation rules
      # For now, all fields are optional
    end
  end
end
