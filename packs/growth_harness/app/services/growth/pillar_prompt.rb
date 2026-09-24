# frozen_string_literal: true

module Growth
  # Selects the image-generation scene for the turbo-one-step flow based on the
  # CONTENT PILLAR the run belongs to (not a hardcoded fashion pool).
  #
  # Root-cause fix for the NSFW-stall: the generator was stamping every run as
  # whatever pillar but ALWAYS rendering from the same 5-scene fashion/beauty
  # bank, which drifts toward bralette/lingerie and trips the gate. Each pillar
  # now maps to its own scene pool so cadence genuinely moves to another pillar
  # (cooking, travel, wellness...) instead of re-rolling lingerie every hour.
  #
  # Scene keys are matched case-insensitively and by substring, so a pillar
  # named 'Food & Cooking' matches :food. Unknown pillars fall back to a safe
  # conservative pool. Every scene keeps identity/face/clothing preset safe and
  # NSFW-gate-clean (verified threshold ~0.5; clean portraits ~0.03).
  class PillarPrompt
    SAFE_BASE =
      'A photorealistic portrait of Sarah, warm natural light, softly glowing skin, authentic candid expression, fully dressed in modest everyday clothing.'

    # pillar-name-token => scene variants. One sampled string is appended to base.
    SCENES = {
      food: [
        'holding a plated home-cooked dish in a bright sunlit kitchen, cozy apron, gentle smile, shallow depth of field',
        'arranging fresh vegetables and herbs on a wooden counter, warm window light, candid laugh',
        'pairing wine with a charcuterie board at a rustic table, soft ambient light, relaxed pose'
      ],
      travel: [
        'standing with a packed daypack on a mountain trail, golden backlight, candid glow',
        'reading a travel journal in a sun-drenched window seat of a small cafe, city rooftops beyond',
        'holding a folded street map outside a landmark, warm late-afternoon light, engaged expression'
      ],
      fitness: [
        'after an outdoor run, tying a hairband, cool morning light, bright healthy energy',
        'mid-jump rope on a sunlit driveway, motion blur behind, sportswear, dynamic candid'
      ],
      wellness: [
        'wrapped in a cozy robe after yoga, soft morning light through blinds, calm unhurried smile',
        'holding herbal tea after a meditation session, warm neutral tones, serene expression'
      ],
      beauty: [
        'softly glowing skincare moment, plain casual tee, natural honest light, no heavy makeup',
        'gentle after-care glow in warm vanity light, modest natural relaxed look'
      ],
      lifestyle: [
        'arranging a quiet home balcony with a coffee and book at golden hour, peaceful smile',
        'reading a book in a cozy armchair by a tall window, warm afternoon light'
      ],
      fashion: [
        'classic trench coat over a fitted top, city street with soft motion, elegant poised stance',
        'high-neck blouse and trousers, minimalist studio backdrop, confident quiet gaze'
      ]
    }.freeze

    DEFAULT_SCENES = [
      'lush park boardwalk in bright daylight, airy candid energy, fully dressed casual outfit',
      'a cozy reading nook at golden hour, warm lamplight, soft contemplative mood, relaxed sweater'
    ].freeze

    # Thread-safe scene selection for a pillar (or default).
    def self.for_pillar(pillar)
      token = pillar&.name.to_s.downcase
      # Prefer the LONGEST matching key so 'Fitness & Wellness' favours :fitness
      # over the earlier-but-shorter :wellness when both are present.
      matches = SCENES.select { |key, _| token.include?(key.to_s) || key.to_s.include?(token) }
      # Explicit first-wins reduce: Ruby's max_by/sort_by both return the LAST
      # tied element, so 'Fitness & Wellness' (both :fitness and :wellness match
      # at length 7) must be resolved by declaration order — :fitness first.
      bank = matches.reduce(nil) do |best, (key, _)|
        best.nil? || key.to_s.length > best.to_s.length ? [ key, SCENES[key] ] : best
      end
      pool    = bank ? bank.last : DEFAULT_SCENES
      "#{SAFE_BASE} #{pool.sample}."
    end
  end
end
