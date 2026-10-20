# frozen_string_literal: true

module CaptionGeneration
  # Ask the vision model a QUESTION about a photo and return its raw answer.
  #
  # VisionGenerator answers "write me a caption" and returns a processed,
  # compliance-checked caption. Some questions are not captions -- "how old does
  # this person appear?" is a SAFETY read whose answer must reach a gate as
  # text, not as copy for the public account. This is that path: same model
  # resolution (ModelConfig.resolve -- the brain, the pipeline's only serving
  # home since ticket #103), same encoder (ImageEncoder), same client -- and it
  # deliberately does NOT post-process, because stripping the model's preamble
  # or hashtags would also strip the answer.
  #
  # Failures are VALUES, never exceptions: a probe whose caller is a pre-publish
  # gate must be able to say "I could not read this" and let publishing continue
  # unchanged, rather than take the queue down with it. That includes the
  # serving home itself: brain not answering -> available: false -> unreadable,
  # with the REASON recorded so the gate's warning names the outage.
  class VisionProbe
    Result = Struct.new(:text, :model, :model_selection, :error, keyword_init: true) do
      def ok?
        error.nil? && text.to_s.strip.present?
      end
    end

    # The answer is a judgement, not a story: temperature 0 keeps two probes of
    # the same render comparable (the whole point of a gate is that the same
    # image gets the same verdict).
    DEFAULT_TEMPERATURE = 0.0

    def self.ask(photo:, question:, temperature: DEFAULT_TEMPERATURE)
      new(photo: photo, question: question, temperature: temperature).ask
    end

    def initialize(photo:, question:, temperature: DEFAULT_TEMPERATURE)
      @photo = photo
      @question = question
      @temperature = temperature
    end

    def ask
      raise ArgumentError, 'Photo must have a readable image' unless ImageEncoder.readable?(@photo)

      load 'lib/ai/brain_client.rb' unless defined?(AI::BrainClient)

      choice = ModelConfig.resolve
      unless choice[:available]
        # Degraded BY VALUE, not by exception: the read is unreadable, the
        # reason is the outage, and nothing was called. The gate logs its own
        # warning (its existing contract) and publishes unchanged (fail-open).
        ModelConfig.log_failure(component: 'vision_probe',
                                error: ModelConfig::UnavailableError.new(choice[:reason]),
                                photo_id: @photo&.id)
        return Result.new(text: '', model: choice[:model], model_selection: choice[:reason],
                          error: choice[:reason])
      end

      result = choice[:client].chat(
        messages: [
          {
            role: 'user',
            content: @question
          }
        ],
        temperature: @temperature,
        images: [ ImageEncoder.encode_base64(@photo) ]
      )

      Result.new(
        text: result[:text].to_s.strip,
        model: result[:model] || choice[:model],
        model_selection: choice[:reason]
      )
    rescue StandardError => e
      ModelConfig.log_failure(component: 'vision_probe', error: e, photo_id: @photo&.id)
      Result.new(text: '', error: "#{e.class}: #{e.message}")
    end
  end
end
