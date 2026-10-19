# frozen_string_literal: true

module CaptionGeneration
  class Result
    attr_reader :text, :metadata, :variations, :success

    def initialize(text:, metadata: {}, variations: [], success: true)
      @text = text
      @metadata = metadata
      @variations = variations
      @success = success
    end

    def success?
      @success
    end

    def failed?
      !@success
    end
  end
end
