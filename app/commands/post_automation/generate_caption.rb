# frozen_string_literal: true

module PostAutomation
  # Step 2: Generate AI caption for the selected photo
  class GenerateCaption < ApplicationCommand
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

      # Route on whether the photo has BYTES we can send, not on whether an
      # ActiveStorage attachment row exists.
      #
      # WHY (2026-09-21): every render the growth harness imports is path-only
      # (import_photo never attaches), so branching on `image.attached?` sent
      # EVERY production caption down the text path and made
      # CaptionGeneration::VisionGenerator unreachable -- the caption was written
      # from the photo's context text, not from the image. Measured: the text
      # path described "rain drumming on the windowpane ... chamomile tea" for a
      # render showing an autumn street scene with a mug, which the vision path
      # described correctly, at 15.0s for a 1.1 MB render on the live caption
      # host. The vision class itself only ever needed readable bytes (its guard
      # was widened for exactly this), so this branch was the last thing holding
      # the image path shut.
      result = if CaptionGeneration::ImageEncoder.readable?(photo)
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
      load "lib/ai/ollama_client.rb" unless defined?(AI::OllamaClient)
    end
  end
end
