# frozen_string_literal: true

module CaptionGeneration
  class ContextBuilder
    def self.build(photo:, cluster: nil)
      new(photo: photo, cluster: cluster).build
    end

    def initialize(photo:, cluster: nil)
      @photo = photo
      @cluster = cluster
    end

    def build
      {
        cluster_name: cluster_name,
        cluster_data: cluster_data,
        persona_name: @photo.persona&.name
      }
    end

    private

    def cluster_name
      @cluster&.name || @photo.content_pillar&.name
    end

    def cluster_data
      pillar = @photo.content_pillar
      return nil unless pillar

      {
        name: pillar.name,
        ai_prompt: pillar.description
      }.compact
    end
  end
end
