# frozen_string_literal: true

module CaptionGeneration
  class PromptBuilder
    def self.build(persona:, context:, avoid_phrases: [])
      new(persona: persona, context: context, avoid_phrases: avoid_phrases).build
    end

    def initialize(persona:, context:, avoid_phrases: [])
      @persona = persona
      @config = persona.caption_config
      @hashtag_strategy = persona.hashtag_strategy
      @context = context
      @avoid_phrases = avoid_phrases
    end

    def build
      {
        system: build_system_prompt,
        user: build_user_prompt
      }
    end

    private

    def build_system_prompt
      <<~PROMPT.strip
        You are a social media caption writer for Instagram.

        IMPORTANT: Write engaging, authentic captions that tell a rich story or share a meaningful moment.
        Good Instagram captions draw readers in, create connection, and provide genuine value.

        Write 4-7 sentences that feel natural and conversational. Share thoughts, feelings, observations, or context.
        Create captions that are substantial, engaging, and authentic - don't be afraid to add personality and detail.
        Paint a picture with words that complements what's in the photo.

        You will receive detailed JSON configuration about the persona's voice, style preferences, and the photo context.
        Use this information to craft the perfect caption.

        You *MUST* only respond with the caption text itself. Do not include any preamble, explanations, or phrases like "Here's the caption:" or "Okay, here's..." - just the caption.
      PROMPT
    end

    def build_user_prompt
      parts = []

      parts << "Please generate a caption for Instagram."

      if @config
        parts << "\nPERSONA CAPTION STRATEGY:"
        parts << "```json"
        parts << JSON.pretty_generate(@config.to_hash)
        parts << "```"
      end

      if @hashtag_strategy
        parts << "\nPERSONA HASHTAG STRATEGY:"
        parts << "```json"
        parts << JSON.pretty_generate(@hashtag_strategy.to_hash)
        parts << "```"
      end

      if @context[:cluster_data]
        parts << "\nCLUSTER CONTEXT:"
        parts << "```json"
        parts << JSON.pretty_generate(@context[:cluster_data])
        parts << "```"
      end

      if @avoid_phrases.any?
        parts << "\nAVOID THESE PHRASES (already used recently):"
        parts << @avoid_phrases.first(10).map { |p| "- #{p}" }.join("\n")
      end

      parts << "\nGenerate a single caption that matches the persona's voice and style from the JSON configuration above."
      parts << "Write 4-7 complete sentences that tell a rich story or share a genuine, detailed moment."
      parts << "Do not include hashtags - they will be added separately."
      parts << "\nIMPORTANT: Respond with ONLY the caption text itself. Do not include any preamble, explanations, or phrases like 'Here's the caption:' or 'Okay, here's...' - just the caption."

      parts.join("\n")
    end
  end
end
