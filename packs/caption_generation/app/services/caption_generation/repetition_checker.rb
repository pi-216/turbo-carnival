# frozen_string_literal: true

module CaptionGeneration
  class RepetitionChecker
    PHRASE_MIN_LENGTH = 3

    def self.extract_phrases(captions)
      new(captions).extract_phrases
    end

    def initialize(captions)
      @captions = captions || []
    end

    def extract_phrases
      phrase_counts = Hash.new(0)

      @captions.each do |caption|
        extract_ngrams(caption, PHRASE_MIN_LENGTH).each do |phrase|
          phrase_counts[phrase] += 1
        end
      end

      phrase_counts.select { |_phrase, count| count >= 2 }.keys
    end

    private

    def extract_ngrams(text, n)
      return [] if text.nil? || text.empty?

      words = text.downcase
                  .gsub(/[^\w\s]/, '')
                  .split
                  .reject { |w| w.length < 3 }

      return [] if words.length < n

      (0..(words.length - n)).map do |i|
        words[i, n].join(' ')
      end
    end
  end
end
