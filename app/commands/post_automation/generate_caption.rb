# frozen_string_literal: true

module PostAutomation
  # Step 2: Generate AI caption for the selected photo
  class GenerateCaption < GLCommand::Callable
    requires photo: ContentPillars::Photo, persona: Persona
    allows pillar: ContentPillar

    returns :caption, :caption_metadata

    def call
      # CaptionGeneration::* autoloads from packs/caption_generation (verified with
      # `rails runner 'defined?(CaptionGeneration::Generator)'` -> "constant"), so
      # the old `Dir[...].each { |f| load f }` glob was unnecessary -- and harmful:
      # `load` re-executes every service file on EVERY caption call, redefining
      # their singleton methods, which silently defeats stubbing in specs and hides
      # the branch that decides whether the caption ever looks at the image.
      load_ollama_client

      result = if photo.image.attached?
        CaptionGeneration::VisionGenerator.generate(
          photo: photo,
          persona: persona,
          content_pillar: pillar
        )
      else
        CaptionGeneration::Generator.generate(
          photo: photo,
          persona: persona,
          cluster: pillar
        )
      end

      if result.success?
        context.caption = result.text
        context.caption_metadata = result.metadata
      else
        stop_and_fail!("Caption generation failed: #{result.metadata[:error]}")
      end
    end

    private

    def load_ollama_client
      # AI::OllamaClient does NOT autoload (lib/ai is not a clean Zeitwerk root),
      # so it must still be loaded explicitly.
      load 'lib/ai/ollama_client.rb' unless defined?(AI::OllamaClient)
    end
  end
end
